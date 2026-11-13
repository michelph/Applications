unit VoxtralClient;

{$mode objfpc}{$H+}

{ Client WebSocket minimaliste pour l'API Mistral Voxtral Realtime :
  wss://api.mistral.ai/v1/audio/transcriptions/realtime?model=...
  TLS via OpenSSL (unité opensslsockets de la FCL), trames RFC 6455,
  lecture dans un thread dédié. Les événements sont déclenchés depuis le
  thread de lecture : les marshaler vers l'UI avec TThread.Queue. }

interface

uses
  Classes, SysUtils, SyncObjs, ctypes, fpjson, sockets, ssockets, sslbase,
  sslsockets, opensslsockets
  {$IFDEF WINDOWS}, winsock2{$ENDIF};

const
  VOXTRAL_HOST = 'api.mistral.ai';
  VOXTRAL_PORT = 443;

type
  TVoxtralNotifyEvent = procedure(Sender: TObject) of object;
  TVoxtralTextEvent = procedure(Sender: TObject; const AText: string) of object;
  TVoxtralErrorEvent = procedure(Sender: TObject; const ACode, AMessage: string) of object;

  TVoxtralClient = class;

  { TVoxtralReaderThread }

  TVoxtralReaderThread = class(TThread)
  private
    FClient: TVoxtralClient;
  protected
    procedure Execute; override;
  public
    constructor Create(AClient: TVoxtralClient);
  end;

  { TVoxtralClient }

  TVoxtralClient = class
  private
    FSocket: TInetSocket;
    FHandler: TOpenSSLSocketHandler;
    FSendLock: TCriticalSection;
    FReader: TVoxtralReaderThread;
    FConnected: Boolean;
    FApiKey: string;
    FPath: string;
    FContOp: Integer;
    FContBuf: AnsiString;
    FOnSessionCreated: TVoxtralNotifyEvent;
    FOnSessionUpdated: TVoxtralNotifyEvent;
    FOnDelta: TVoxtralTextEvent;
    FOnDone: TVoxtralTextEvent;
    FOnError: TVoxtralErrorEvent;
    FOnClosed: TVoxtralNotifyEvent;
    function BuildHandshakeKey: string;
    procedure Handshake;
    function SendAll(const ABuf; ACount: Integer): Boolean;
    procedure SendFrameRaw(AOpcode: Byte; const APayload: AnsiString);
    function RecvExact(var ABuf; ACount: Integer): Boolean;
    function ReadHttpResponseHeaders: string;
    function ReadFrame(out AOpcode: Integer; out APayload: AnsiString): Boolean;
    procedure HandleMessage(const AMsg: AnsiString);
    function WaitForSocketData(ATimeoutUs: Integer): Integer;
    procedure ReaderLoop;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(const AModel, AApiKey: string);
    procedure Close;
    procedure ConfigureSession(ASampleRate, ADelayMs: Integer; const ALanguage: string);
    procedure SendAudioChunk(AData: PByte; ASize: Integer);
    procedure SendAudioEnd;
    property Connected: Boolean read FConnected;
    property OnSessionCreated: TVoxtralNotifyEvent read FOnSessionCreated write FOnSessionCreated;
    property OnSessionUpdated: TVoxtralNotifyEvent read FOnSessionUpdated write FOnSessionUpdated;
    property OnDelta: TVoxtralTextEvent read FOnDelta write FOnDelta;
    property OnDone: TVoxtralTextEvent read FOnDone write FOnDone;
    property OnError: TVoxtralErrorEvent read FOnError write FOnError;
    property OnClosed: TVoxtralNotifyEvent read FOnClosed write FOnClosed;
  end;

implementation

const
  C_B64: array[0..63] of AnsiChar =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function Base64Encode(const AData: PByte; ALen: Integer): string;
var
  I, O: Integer;
  A, B, C: Byte;
begin
  SetLength(Result, ((ALen + 2) div 3) * 4);
  O := 1;
  I := 0;
  while I + 3 <= ALen do
  begin
    A := AData[I];
    B := AData[I + 1];
    C := AData[I + 2];
    Result[O] := C_B64[A shr 2];
    Result[O + 1] := C_B64[((A and 3) shl 4) or (B shr 4)];
    Result[O + 2] := C_B64[((B and 15) shl 2) or (C shr 6)];
    Result[O + 3] := C_B64[C and 63];
    Inc(O, 4);
    Inc(I, 3);
  end;
  if ALen - I = 1 then
  begin
    A := AData[I];
    Result[O] := C_B64[A shr 2];
    Result[O + 1] := C_B64[(A and 3) shl 4];
    Result[O + 2] := '=';
    Result[O + 3] := '=';
  end
  else if ALen - I = 2 then
  begin
    A := AData[I];
    B := AData[I + 1];
    Result[O] := C_B64[A shr 2];
    Result[O + 1] := C_B64[((A and 3) shl 4) or (B shr 4)];
    Result[O + 2] := C_B64[(B and 15) shl 2];
    Result[O + 3] := '=';
  end;
end;

{ TVoxtralReaderThread }

constructor TVoxtralReaderThread.Create(AClient: TVoxtralClient);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FClient := AClient;
end;

procedure TVoxtralReaderThread.Execute;
begin
  FClient.ReaderLoop;
end;

{ TVoxtralClient }

constructor TVoxtralClient.Create;
begin
  inherited Create;
  Randomize;
  FSendLock := TCriticalSection.Create;
  FSocket := nil;
  FHandler := nil;
  FReader := nil;
  FConnected := False;
  FContOp := 0;
  FContBuf := '';
end;

destructor TVoxtralClient.Destroy;
begin
  Close;
  FSendLock.Free;
  inherited Destroy;
end;

procedure TVoxtralClient.Connect(const AModel, AApiKey: string);
begin
  if FConnected then
    Exit;
  FApiKey := AApiKey;
  FPath := '/v1/audio/transcriptions/realtime?model=' + AModel;
  FHandler := TOpenSSLSocketHandler.Create;
  if FileExists('cacert.pem') then
  begin
    FHandler.CertificateData.CertCA.FileName := 'cacert.pem';
    FHandler.VerifyPeerCert := True;
  end
  else
    FHandler.VerifyPeerCert := False;
  FHandler.SSLType := stTLSv1_2;
  FHandler.SendHostAsSNI := True;
  FSocket := TInetSocket.Create(VOXTRAL_HOST, VOXTRAL_PORT, 10000, FHandler);
  FSocket.IOTimeout := 5000;
  try
    FSocket.Connect;
  except
    FreeAndNil(FSocket);
    FHandler := nil;
    raise;
  end;
  Handshake;
  FConnected := True;
  FReader := TVoxtralReaderThread.Create(Self);
  FReader.Start;
end;

procedure TVoxtralClient.Handshake;
var
  Req: AnsiString;
  Resp: string;
  Line: string;
begin
  Req :=
    'GET ' + FPath + ' HTTP/1.1'#13#10 +
    'Host: ' + VOXTRAL_HOST + #13#10 +
    'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Key: ' + BuildHandshakeKey + #13#10 +
    'Sec-WebSocket-Version: 13'#13#10 +
    'Authorization: Bearer ' + FApiKey + #13#10 +
    'User-Agent: VoxtralLazarus/1.0'#13#10#13#10;
  if not SendAll(Req[1], Length(Req)) then
    raise Exception.Create('Échec d''envoi de la requête WebSocket.');
  Resp := ReadHttpResponseHeaders;
  Line := Copy(Resp, 1, Pos(#13#10, Resp) - 1);
  if Pos(' 101', Line) = 0 then
    raise Exception.Create('Connexion WebSocket refusée : ' + Line);
end;

function TVoxtralClient.BuildHandshakeKey: string;
var
  Raw: array[0..15] of Byte;
  I: Integer;
begin
  for I := 0 to 15 do
    Raw[I] := Random(256);
  Result := Base64Encode(@Raw[0], 16);
end;

function TVoxtralClient.ReadHttpResponseHeaders: string;
var
  Ch: AnsiChar;
  Buf: AnsiString;
begin
  Result := '';
  Buf := '';
  while Length(Buf) < 8192 do
  begin
    if not RecvExact(Ch, 1) then
      raise Exception.Create('Connexion interrompue pendant le handshake.');
    Buf := Buf + Ch;
    if Copy(Buf, Length(Buf) - 3, 4) = #13#10#13#10 then
      Break;
  end;
  Result := Buf;
end;

function TVoxtralClient.SendAll(const ABuf; ACount: Integer): Boolean;
var
  P: PByte;
  Sent, N: Integer;
begin
  Result := False;
  if ACount <= 0 then
    Exit(True);
  P := @ABuf;
  Sent := 0;
  while Sent < ACount do
  begin
    N := FSocket.Write(P^, ACount - Sent);
    if N <= 0 then
      Exit;
    Inc(P, N);
    Inc(Sent, N);
  end;
  Result := True;
end;

procedure TVoxtralClient.SendFrameRaw(AOpcode: Byte; const APayload: AnsiString);
var
  Hdr: array[0..13] of Byte;
  Mask: array[0..3] of Byte;
  Data: TBytes;
  Len, HLen, I: Integer;
begin
  Len := Length(APayload);
  SetLength(Data, Len);
  if Len > 0 then
    Move(APayload[1], Data[0], Len);
  Hdr[0] := $80 or (AOpcode and $0F);
  HLen := 2;
  if Len < 126 then
    Hdr[1] := $80 or Byte(Len)
  else if Len < 65536 then
  begin
    Hdr[1] := $80 or 126;
    Hdr[2] := Byte(Len shr 8);
    Hdr[3] := Byte(Len);
    HLen := 4;
  end
  else
  begin
    Hdr[1] := $80 or 127;
    FillChar(Hdr[2], 8, 0);
    Hdr[6] := Byte(Len shr 24);
    Hdr[7] := Byte(Len shr 16);
    Hdr[8] := Byte(Len shr 8);
    Hdr[9] := Byte(Len);
    HLen := 10;
  end;
  for I := 0 to 3 do
    Mask[I] := Random(256);
  for I := 0 to Len - 1 do
    Data[I] := Data[I] xor Mask[I mod 4];
  Hdr[HLen] := Mask[0];
  Hdr[HLen + 1] := Mask[1];
  Hdr[HLen + 2] := Mask[2];
  Hdr[HLen + 3] := Mask[3];
  Inc(HLen, 4);
  FSendLock.Enter;
  try
    if not SendAll(Hdr, HLen) then
      Exit;
    if Len > 0 then
      SendAll(Data[0], Len);
  finally
    FSendLock.Leave;
  end;
end;

function TVoxtralClient.RecvExact(var ABuf; ACount: Integer): Boolean;
var
  P: PByte;
  Got, N: Integer;
begin
  Result := False;
  P := @ABuf;
  Got := 0;
  while Got < ACount do
  begin
    N := FSocket.Read(P^, ACount - Got);
    if N <= 0 then
      Exit;
    Inc(P, N);
    Inc(Got, N);
  end;
  Result := True;
end;

function TVoxtralClient.ReadFrame(out AOpcode: Integer; out APayload: AnsiString): Boolean;
var
  H: array[0..1] of Byte;
  Ext: array[0..7] of Byte;
  MaskKey: array[0..3] of Byte;
  Len: Int64;
  Fin, Masked: Boolean;
  I: Integer;
begin
  Result := False;
  AOpcode := -1;
  APayload := '';
  if not RecvExact(H, 2) then
    Exit;
  Fin := (H[0] and $80) <> 0;
  AOpcode := H[0] and $0F;
  Masked := (H[1] and $80) <> 0;
  Len := H[1] and $7F;
  if Len = 126 then
  begin
    if not RecvExact(Ext, 2) then
      Exit;
    Len := (Int64(Ext[0]) shl 8) or Ext[1];
  end
  else if Len = 127 then
  begin
    if not RecvExact(Ext, 8) then
      Exit;
    Len := 0;
    for I := 0 to 7 do
      Len := (Len shl 8) or Ext[I];
  end;
  if Len > 16 * 1024 * 1024 then
    Exit;
  if Masked then
    if not RecvExact(MaskKey, 4) then
      Exit;
  SetLength(APayload, Len);
  if Len > 0 then
    if not RecvExact(APayload[1], Len) then
      Exit;
  if Masked then
    for I := 1 to Len do
      APayload[I] := AnsiChar(Byte(APayload[I]) xor MaskKey[(I - 1) mod 4]);
  if not Fin then
  begin
    if (AOpcode = 1) or (AOpcode = 2) then
    begin
      FContOp := AOpcode;
      FContBuf := APayload;
      AOpcode := -2;
      APayload := '';
    end
    else if AOpcode = 0 then
    begin
      FContBuf := FContBuf + APayload;
      AOpcode := -2;
      APayload := '';
    end;
  end
  else if AOpcode = 0 then
  begin
    AOpcode := FContOp;
    APayload := FContBuf + APayload;
    FContBuf := '';
    FContOp := 0;
  end;
  Result := True;
end;

procedure TVoxtralClient.HandleMessage(const AMsg: AnsiString);
var
  J: TJSONData;
  O: TJSONObject;
  T, Code, Msg: string;
  E: TJSONData;
begin
  J := GetJSON(AMsg);
  try
    if not (J is TJSONObject) then
      Exit;
    O := TJSONObject(J);
    T := O.Get('type', '');
    if T = 'session.created' then
    begin
      if Assigned(FOnSessionCreated) then
        FOnSessionCreated(Self);
    end
    else if T = 'session.updated' then
    begin
      if Assigned(FOnSessionUpdated) then
        FOnSessionUpdated(Self);
    end
    else if T = 'transcription.text.delta' then
    begin
      if Assigned(FOnDelta) then
        FOnDelta(Self, O.Get('text', ''));
    end
    else if T = 'transcription.done' then
    begin
      if Assigned(FOnDone) then
        FOnDone(Self, O.Get('text', ''));
    end
    else if T = 'error' then
    begin
      E := O.FindPath('error.code');
      if E <> nil then
        Code := E.AsString
      else
        Code := '';
      E := O.FindPath('error.message');
      if E <> nil then
        Msg := E.AsString
      else
        Msg := AMsg;
      if Assigned(FOnError) then
        FOnError(Self, Code, Msg);
    end;
  finally
    J.Free;
  end;
end;

function TVoxtralClient.WaitForSocketData(ATimeoutUs: Integer): Integer;
{$IFDEF WINDOWS}
var
  FDs: TFDSet;
  TV: TTimeVal;
begin
  winsock2.FD_Zero(FDs);
  winsock2.FD_Set(TSocket(FSocket.Handle), FDs);
  TV.tv_sec := ATimeoutUs div 1000000;
  TV.tv_usec := ATimeoutUs mod 1000000;
  Result := winsock2.Select(TSocket(FSocket.Handle) + 1, @FDs, nil, nil, @TV);
{$ELSE}
var
  FDs: sockets.TFDSet;
  TV: sockets.TTimeVal;
begin
  sockets.fpFD_Zero(FDs);
  sockets.fpFD_Set(cint(FSocket.Handle), FDs);
  TV.tv_sec := ATimeoutUs div 1000000;
  TV.tv_usec := ATimeoutUs mod 1000000;
  Result := sockets.fpSelect(cint(FSocket.Handle) + 1, @FDs, nil, nil, @TV);
{$ENDIF}
end;

procedure TVoxtralClient.ReaderLoop;
var
  Op: Integer;
  Payload: AnsiString;
  R: Integer;
begin
  try
    while FConnected and not FReader.Terminated do
    begin
      if FHandler.BytesAvailable > 0 then
        R := 1
      else
      begin
        R := WaitForSocketData(200000);
        if R < 0 then
          Break;
      end;
      if R > 0 then
      begin
        if not ReadFrame(Op, Payload) then
          Break;
        if Op = 1 then
          HandleMessage(Payload)
        else if Op = 8 then
          Break
        else if Op = 9 then
          SendFrameRaw(10, Payload);
      end;
    end;
  except
    on E: Exception do
      if FConnected and Assigned(FOnError) then
        FOnError(Self, 'network', E.Message);
  end;
  FConnected := False;
  if Assigned(FOnClosed) then
    FOnClosed(Self);
end;

procedure TVoxtralClient.ConfigureSession(ASampleRate, ADelayMs: Integer;
  const ALanguage: string);
var
  J, Sess, AF: TJSONObject;
begin
  AF := TJSONObject.Create;
  AF.Add('encoding', 'pcm_s16le');
  AF.Add('sample_rate', ASampleRate);
  Sess := TJSONObject.Create;
  Sess.Add('audio_format', AF);
  Sess.Add('target_streaming_delay_ms', ADelayMs);
  if ALanguage <> '' then
    Sess.Add('language', ALanguage);
  J := TJSONObject.Create;
  try
    J.Add('type', 'session.update');
    J.Add('session', Sess);
    SendFrameRaw(1, J.AsJSON);
  finally
    J.Free;
  end;
end;

procedure TVoxtralClient.SendAudioChunk(AData: PByte; ASize: Integer);
var
  J: TJSONObject;
begin
  if not FConnected then
    Exit;
  J := TJSONObject.Create;
  try
    J.Add('type', 'input_audio.append');
    J.Add('audio', Base64Encode(AData, ASize));
    SendFrameRaw(1, J.AsJSON);
  finally
    J.Free;
  end;
end;

procedure TVoxtralClient.SendAudioEnd;
var
  J: TJSONObject;
begin
  if not FConnected then
    Exit;
  J := TJSONObject.Create;
  try
    J.Add('type', 'input_audio.end');
    SendFrameRaw(1, J.AsJSON);
  finally
    J.Free;
  end;
end;

procedure TVoxtralClient.Close;
begin
  if FReader <> nil then
  begin
    FConnected := False;
    FReader.Terminate;
    FReader.WaitFor;
    FreeAndNil(FReader);
  end;
  FreeAndNil(FSocket);
  FHandler := nil;
  FConnected := False;
end;

end.
