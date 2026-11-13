unit AudioCapture;

{$mode objfpc}{$H+}

{ Capture micro Windows via MMSystem (waveIn) : PCM 16 kHz, mono, 16 bits.
  Les chunks audio (100 ms) sont poussés dans un anneau et distribués par un
  thread dédié via l'événement OnChunk (appelé hors thread principal). }

interface

uses
  Classes, SysUtils, SyncObjs, Windows, MMSystem;

const
  AC_SAMPLE_RATE      = 16000;
  AC_NUM_CHANNELS     = 1;
  AC_BITS_PER_SAMPLE  = 16;
  AC_CHUNK_MS         = 100;
  AC_CHUNK_BYTES      = (AC_SAMPLE_RATE * (AC_BITS_PER_SAMPLE div 8) * AC_CHUNK_MS) div 1000;
  AC_RING_SIZE        = 16;

type
  TAudioChunkEvent = procedure(Sender: TObject; const AData: PByte; ASize: Integer) of object;

  TChunkRecord = record
    Data: array[0..AC_CHUNK_BYTES - 1] of Byte;
    Size: Integer;
  end;

  TAudioCapture = class;

  { TPumpThread }

  TPumpThread = class(TThread)
  private
    FCapture: TAudioCapture;
  protected
    procedure Execute; override;
  public
    constructor Create(ACapture: TAudioCapture);
  end;

  { TAudioCapture }

  TAudioCapture = class
  private
    FCrit: TRTLCriticalSection;
    FDataEvent: TEvent;
    FRing: array[0..AC_RING_SIZE - 1] of TChunkRecord;
    FWriteIdx, FReadIdx: Integer;
    FDropped: Integer;
    FTempBuf: array[0..AC_CHUNK_BYTES - 1] of Byte;
    FFormat: TWAVEFORMATEX;
    FWaveIn: HWAVEIN;
    FHeaders: array[0..AC_RING_SIZE - 1] of TWAVEHDR;
    FBuffers: array[0..AC_RING_SIZE - 1] of PByte;
    FBufferCount: Integer;
    FRecording: Boolean;
    FPump: TPumpThread;
    FOnChunk: TAudioChunkEvent;
    FWavStream: TFileStream;
    FWavDataBytes: Int64;
    procedure Enqueue(AData: PByte; ASize: Integer);
    function PumpChunk: Boolean;
    procedure WriteWavData(AData: PByte; ASize: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    function Start: Boolean;
    procedure Stop;
    function StartWav(const AFileName: string): Boolean;
    procedure StopWav;
    property OnChunk: TAudioChunkEvent read FOnChunk write FOnChunk;
    property Dropped: Integer read FDropped;
  end;

implementation

var
  GActiveCapture: TAudioCapture = nil;
  GCrit: TRTLCriticalSection;

procedure WaveInCallback(hwi: HWAVEIN; uMsg: UINT; dwInstance: DWORD;
  dwParam1: DWORD; dwParam2: DWORD); stdcall;
var
  Cap: TAudioCapture;
  Hdr: PWAVEHDR;
begin
  if uMsg <> WIM_DATA then
    Exit;
  Cap := TAudioCapture(Pointer(dwInstance));
  if (Cap = nil) or (Cap <> GActiveCapture) then
    Exit;
  Hdr := PWAVEHDR(Pointer(dwParam1));
  if Hdr^.dwBytesRecorded > 0 then
    Cap.Enqueue(PByte(Hdr^.lpData), Hdr^.dwBytesRecorded);
  if Cap.FRecording then
    waveInAddBuffer(hwi, Hdr, SizeOf(TWAVEHDR));
end;

{ TPumpThread }

constructor TPumpThread.Create(ACapture: TAudioCapture);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FCapture := ACapture;
end;

procedure TPumpThread.Execute;
begin
  while not Terminated do
  begin
    if FCapture.FDataEvent.WaitFor(200) <> wrSignaled then
      Continue;
    while (not Terminated) and FCapture.PumpChunk do
      ;
  end;
end;

{ TAudioCapture }

constructor TAudioCapture.Create;
begin
  inherited Create;
  InitializeCriticalSection(FCrit);
  FDataEvent := TEvent.Create(nil, False, False, '');
  FWriteIdx := 0;
  FReadIdx := 0;
  FDropped := 0;
  FBufferCount := 0;
  FRecording := False;
  FWaveIn := 0;
  FWavStream := nil;
end;

destructor TAudioCapture.Destroy;
begin
  Stop;
  StopWav;
  FDataEvent.Free;
  DeleteCriticalSection(FCrit);
  inherited Destroy;
end;

procedure TAudioCapture.Enqueue(AData: PByte; ASize: Integer);
var
  Idx: Integer;
begin
  if ASize > AC_CHUNK_BYTES then
    ASize := AC_CHUNK_BYTES;
  if ASize <= 0 then
    Exit;
  EnterCriticalSection(FCrit);
  try
    Idx := FWriteIdx;
    if ((Idx + 1) mod AC_RING_SIZE) = FReadIdx then
    begin
      Inc(FDropped);
      Exit;
    end;
    Move(AData^, FRing[Idx].Data[0], ASize);
    FRing[Idx].Size := ASize;
    FWriteIdx := (Idx + 1) mod AC_RING_SIZE;
  finally
    LeaveCriticalSection(FCrit);
  end;
  FDataEvent.SetEvent;
end;

function TAudioCapture.PumpChunk: Boolean;
var
  Idx, Size: Integer;
begin
  Result := False;
  EnterCriticalSection(FCrit);
  try
    if FReadIdx = FWriteIdx then
      Exit;
    Idx := FReadIdx;
    Size := FRing[Idx].Size;
    Move(FRing[Idx].Data[0], FTempBuf[0], Size);
    FReadIdx := (Idx + 1) mod AC_RING_SIZE;
  finally
    LeaveCriticalSection(FCrit);
  end;
  WriteWavData(@FTempBuf[0], Size);
  if Assigned(FOnChunk) then
    FOnChunk(Self, @FTempBuf[0], Size);
  Result := True;
end;

function TAudioCapture.Start: Boolean;
var
  res: MMRESULT;
  i: Integer;
begin
  Result := False;
  if FRecording then
    Exit;
  EnterCriticalSection(GCrit);
  try
    GActiveCapture := Self;
  finally
    LeaveCriticalSection(GCrit);
  end;
  FillChar(FFormat, SizeOf(FFormat), 0);
  FFormat.wFormatTag := WAVE_FORMAT_PCM;
  FFormat.nChannels := AC_NUM_CHANNELS;
  FFormat.nSamplesPerSec := AC_SAMPLE_RATE;
  FFormat.wBitsPerSample := AC_BITS_PER_SAMPLE;
  FFormat.nBlockAlign := (AC_BITS_PER_SAMPLE div 8) * AC_NUM_CHANNELS;
  FFormat.nAvgBytesPerSec := AC_SAMPLE_RATE * FFormat.nBlockAlign;
  res := waveInOpen(@FWaveIn, WAVE_MAPPER, @FFormat, DWORD_PTR(@WaveInCallback),
    DWORD_PTR(Self), CALLBACK_FUNCTION);
  if res <> MMSYSERR_NOERROR then
  begin
    FWaveIn := 0;
    EnterCriticalSection(GCrit);
    try
      if GActiveCapture = Self then
        GActiveCapture := nil;
    finally
      LeaveCriticalSection(GCrit);
    end;
    Exit;
  end;
  FBufferCount := 4;
  for i := 0 to FBufferCount - 1 do
  begin
    GetMem(FBuffers[i], AC_CHUNK_BYTES);
    FillChar(FHeaders[i], SizeOf(TWAVEHDR), 0);
    FHeaders[i].lpData := PChar(FBuffers[i]);
    FHeaders[i].dwBufferLength := AC_CHUNK_BYTES;
    waveInPrepareHeader(FWaveIn, @FHeaders[i], SizeOf(TWAVEHDR));
    waveInAddBuffer(FWaveIn, @FHeaders[i], SizeOf(TWAVEHDR));
  end;
  FRecording := True;
  FPump := TPumpThread.Create(Self);
  FPump.Start;
  waveInStart(FWaveIn);
  Result := True;
end;

procedure TAudioCapture.Stop;
var
  i: Integer;
begin
  if FWaveIn <> 0 then
  begin
    FRecording := False;
    waveInReset(FWaveIn);
    for i := 0 to FBufferCount - 1 do
      waveInUnprepareHeader(FWaveIn, @FHeaders[i], SizeOf(TWAVEHDR));
    waveInClose(FWaveIn);
    FWaveIn := 0;
  end;
  if Assigned(FPump) then
  begin
    FPump.Terminate;
    FDataEvent.SetEvent;
    FPump.WaitFor;
    FreeAndNil(FPump);
  end;
  for i := 0 to FBufferCount - 1 do
    if FBuffers[i] <> nil then
    begin
      FreeMem(FBuffers[i]);
      FBuffers[i] := nil;
    end;
  FBufferCount := 0;
  EnterCriticalSection(GCrit);
  try
    if GActiveCapture = Self then
      GActiveCapture := nil;
  finally
    LeaveCriticalSection(GCrit);
  end;
end;

function TAudioCapture.StartWav(const AFileName: string): Boolean;
var
  Hdr: array[0..43] of Byte;

  procedure PutStr(AOff: Integer; const S: string);
  begin
    Move(S[1], Hdr[AOff], Length(S));
  end;

  procedure PutDWord(AOff, AValue: Integer);
  begin
    Move(AValue, Hdr[AOff], 4);
  end;

  procedure PutWord(AOff, AValue: Integer);
  begin
    Move(AValue, Hdr[AOff], 2);
  end;

begin
  Result := False;
  EnterCriticalSection(FCrit);
  try
    if FWavStream <> nil then
      Exit;
    FWavStream := TFileStream.Create(AFileName, fmCreate);
    FWavDataBytes := 0;
    FillChar(Hdr, SizeOf(Hdr), 0);
    PutStr(0, 'RIFF');
    PutDWord(4, 0);
    PutStr(8, 'WAVE');
    PutStr(12, 'fmt ');
    PutDWord(16, 16);
    PutWord(20, 1);
    PutWord(22, AC_NUM_CHANNELS);
    PutDWord(24, AC_SAMPLE_RATE);
    PutDWord(28, AC_SAMPLE_RATE * AC_NUM_CHANNELS * (AC_BITS_PER_SAMPLE div 8));
    PutWord(32, AC_NUM_CHANNELS * (AC_BITS_PER_SAMPLE div 8));
    PutWord(34, AC_BITS_PER_SAMPLE);
    PutStr(36, 'data');
    PutDWord(40, 0);
    FWavStream.WriteBuffer(Hdr, SizeOf(Hdr));
    Result := True;
  finally
    LeaveCriticalSection(FCrit);
  end;
end;

procedure TAudioCapture.StopWav;
var
  RiffSize, DataSize: LongInt;
begin
  EnterCriticalSection(FCrit);
  try
    if FWavStream = nil then
      Exit;
    DataSize := FWavDataBytes;
    RiffSize := 36 + DataSize;
    FWavStream.Position := 4;
    FWavStream.WriteBuffer(RiffSize, 4);
    FWavStream.Position := 40;
    FWavStream.WriteBuffer(DataSize, 4);
    FreeAndNil(FWavStream);
  finally
    LeaveCriticalSection(FCrit);
  end;
end;

procedure TAudioCapture.WriteWavData(AData: PByte; ASize: Integer);
begin
  EnterCriticalSection(FCrit);
  try
    if FWavStream <> nil then
    begin
      FWavStream.WriteBuffer(AData^, ASize);
      Inc(FWavDataBytes, ASize);
    end;
  finally
    LeaveCriticalSection(FCrit);
  end;
end;

initialization
  InitializeCriticalSection(GCrit);

finalization
  DeleteCriticalSection(GCrit);

end.
