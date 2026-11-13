unit main;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, SyncObjs, Forms, Controls, Dialogs, StdCtrls,
  ExtCtrls, Spin, AudioCapture, VoxtralClient;

type

  { Événements UI marshalés depuis les threads de capture/lecture }

  TUIEventKind = (
    uekSessionCreated,
    uekSessionUpdated,
    uekDelta,
    uekDone,
    uekError,
    uekClosed,
    uekStatus
  );

  TUIEvent = record
    Kind: TUIEventKind;
    Text1: string;
    Text2: string;
  end;

  TUIEventQueue = class
  private
    FCrit: TRTLCriticalSection;
    FItems: array of TUIEvent;
    FHead, FTail: Integer;
    procedure Grow;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Push(const AEvent: TUIEvent);
    function Pop(out AEvent: TUIEvent): Boolean;
  end;

  { TMainForm }

  TMainForm = class(TForm)
    btnEffacer: TButton;
    btnStart: TButton;
    btnStop: TButton;
    chkWav: TCheckBox;
    cmbLangue: TComboBox;
    cmbModele: TComboBox;
    edtApiKey: TEdit;
    edtWav: TEdit;
    lblApiKey: TLabel;
    lblDelai: TLabel;
    lblEtat: TLabel;
    lblLangue: TLabel;
    lblModele: TLabel;
    memTranscript: TMemo;
    pnlBottom: TPanel;
    pnlTop: TPanel;
    seDelai: TSpinEdit;
    procedure btnEffacerClick(Sender: TObject);
    procedure btnStartClick(Sender: TObject);
    procedure btnStopClick(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
  private
    FCapture: TAudioCapture;
    FClient: TVoxtralClient;
    FEvents: TUIEventQueue;
    FRunning: Boolean;
    FChunkCount: Integer;
    procedure SetEtat(const AText: string);
    procedure SetRunning(ARunning: Boolean);
    procedure StopSession;
    procedure PostEvent(AKind: TUIEventKind; const AText1: string = '';
      const AText2: string = '');
    procedure DrainUIEvents;
    procedure HandleChunk(Sender: TObject; const AData: PByte; ASize: Integer);
    procedure ClientSessionCreated(Sender: TObject);
    procedure ClientSessionUpdated(Sender: TObject);
    procedure ClientDelta(Sender: TObject; const AText: string);
    procedure ClientDone(Sender: TObject; const AText: string);
    procedure ClientError(Sender: TObject; const ACode, AMessage: string);
    procedure ClientClosed(Sender: TObject);
  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

{ TUIEventQueue }

constructor TUIEventQueue.Create;
begin
  inherited Create;
  InitializeCriticalSection(FCrit);
  FHead := 0;
  FTail := 0;
end;

destructor TUIEventQueue.Destroy;
begin
  SetLength(FItems, 0);
  DeleteCriticalSection(FCrit);
  inherited Destroy;
end;

procedure TUIEventQueue.Grow;
var
  Old: array of TUIEvent;
  OldCap, Count, NewCap, I: Integer;
begin
  OldCap := Length(FItems);
  Count := 0;
  if OldCap > 0 then
    Count := (FTail - FHead + OldCap) mod OldCap;
  Old := FItems;
  FItems := nil;
  NewCap := 16;
  while NewCap <= Count + 1 do
    NewCap := NewCap * 2;
  SetLength(FItems, NewCap);
  for I := 0 to Count - 1 do
    FItems[I] := Old[(FHead + I) mod OldCap];
  FHead := 0;
  FTail := Count;
end;

procedure TUIEventQueue.Push(const AEvent: TUIEvent);
var
  Idx: Integer;
begin
  EnterCriticalSection(FCrit);
  try
    if (Length(FItems) = 0) or
       (((FTail + 1) mod Length(FItems)) = FHead) then
    begin
      Grow;
    end;
    FItems[FTail] := AEvent;
    FTail := (FTail + 1) mod Length(FItems);
  finally
    LeaveCriticalSection(FCrit);
  end;
end;

function TUIEventQueue.Pop(out AEvent: TUIEvent): Boolean;
begin
  Result := False;
  EnterCriticalSection(FCrit);
  try
    if Length(FItems) = 0 then
      Exit;
    if FHead = FTail then
      Exit;
    AEvent := FItems[FHead];
    FItems[FHead] := Default(TUIEvent);
    FHead := (FHead + 1) mod Length(FItems);
    Result := True;
  finally
    LeaveCriticalSection(FCrit);
  end;
end;

{ TMainForm }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  FCapture := nil;
  FClient := nil;
  FEvents := TUIEventQueue.Create;
  FRunning := False;
  FChunkCount := 0;
  btnStop.Enabled := False;
  lblEtat.Caption := 'Prêt.';
end;

procedure TMainForm.SetEtat(const AText: string);
begin
  lblEtat.Caption := AText;
end;

procedure TMainForm.SetRunning(ARunning: Boolean);
begin
  FRunning := ARunning;
  btnStart.Enabled := not ARunning;
  btnStop.Enabled := ARunning;
end;

procedure TMainForm.PostEvent(AKind: TUIEventKind; const AText1: string;
  const AText2: string);
var
  E: TUIEvent;
begin
  E := Default(TUIEvent);
  E.Kind := AKind;
  E.Text1 := AText1;
  E.Text2 := AText2;
  FEvents.Push(E);
  TThread.Queue(nil, @DrainUIEvents);
end;

procedure TMainForm.DrainUIEvents;
var
  E: TUIEvent;
begin
  while FEvents.Pop(E) do
  begin
    case E.Kind of
      uekSessionCreated:
        begin
          SetEtat('Session créée, configuration…');
          if FClient <> nil then
            FClient.ConfigureSession(AC_SAMPLE_RATE, seDelai.Value,
              IfThen(cmbLangue.Text = '(auto)', '', cmbLangue.Text));
        end;
      uekSessionUpdated:
        begin
          if FClient = nil then
            Continue;
          FCapture := TAudioCapture.Create;
          FCapture.OnChunk := @HandleChunk;
          if chkWav.Checked and (Trim(edtWav.Text) <> '') then
          begin
            if FCapture.StartWav(Trim(edtWav.Text)) then
              SetEtat('Écoute du micro (WAV : ' + Trim(edtWav.Text) + ')…')
            else
              SetEtat('Écoute du micro (échec de l''enregistrement WAV)…');
          end
          else
            SetEtat('Écoute du micro…');
          if not FCapture.Start then
          begin
            SetEtat('Impossible d''ouvrir le microphone (waveIn).');
            FreeAndNil(FCapture);
            FClient.Close;
            SetRunning(False);
          end;
        end;
      uekDelta:
        begin
          memTranscript.SelStart := Length(memTranscript.Text);
          memTranscript.SelText := E.Text1;
        end;
      uekDone:
        begin
          SetEtat('Transcription terminée.');
          StopSession;
          SetRunning(False);
        end;
      uekError:
        begin
          memTranscript.Lines.Add('[Erreur ' + E.Text1 + '] ' + E.Text2);
          SetEtat('Erreur : ' + E.Text2);
          StopSession;
          SetRunning(False);
        end;
      uekClosed:
        FreeAndNil(FClient);
      uekStatus:
        SetEtat(E.Text1);
    end;
  end;
end;

procedure TMainForm.btnStartClick(Sender: TObject);
begin
  if FRunning then
    Exit;
  if Trim(edtApiKey.Text) = '' then
  begin
    ShowMessage('Renseignez votre clé API Mistral.');
    Exit;
  end;
  memTranscript.Clear;
  FChunkCount := 0;
  FClient := TVoxtralClient.Create;
  FClient.OnSessionCreated := @ClientSessionCreated;
  FClient.OnSessionUpdated := @ClientSessionUpdated;
  FClient.OnDelta := @ClientDelta;
  FClient.OnDone := @ClientDone;
  FClient.OnError := @ClientError;
  FClient.OnClosed := @ClientClosed;
  SetRunning(True);
  SetEtat('Connexion à l''API Voxtral…');
  try
    FClient.Connect(cmbModele.Text, Trim(edtApiKey.Text));
  except
    on E: Exception do
    begin
      SetEtat('Échec de connexion : ' + E.Message);
      SetRunning(False);
      FreeAndNil(FClient);
    end;
  end;
end;

procedure TMainForm.btnStopClick(Sender: TObject);
begin
  if FCapture <> nil then
  begin
    FCapture.StopWav;
    FCapture.Stop;
    FreeAndNil(FCapture);
  end;
  if FClient <> nil then
  begin
    SetEtat('Finalisation de la transcription…');
    FClient.SendAudioEnd;
  end;
end;

procedure TMainForm.btnEffacerClick(Sender: TObject);
begin
  memTranscript.Clear;
end;

procedure TMainForm.StopSession;
begin
  if FCapture <> nil then
  begin
    FCapture.StopWav;
    FCapture.Stop;
    FreeAndNil(FCapture);
  end;
  if FClient <> nil then
    FClient.Close;
end;

procedure TMainForm.HandleChunk(Sender: TObject; const AData: PByte; ASize: Integer);
begin
  if (FClient <> nil) and FClient.Connected then
    FClient.SendAudioChunk(AData, ASize);
  Inc(FChunkCount);
  if FChunkCount mod 10 = 0 then
    PostEvent(uekStatus, Format('Écoute du micro… (%d Ko envoyés)',
      [FChunkCount * AC_CHUNK_BYTES div 1024]));
end;

procedure TMainForm.ClientSessionCreated(Sender: TObject);
begin
  PostEvent(uekSessionCreated);
end;

procedure TMainForm.ClientSessionUpdated(Sender: TObject);
begin
  PostEvent(uekSessionUpdated);
end;

procedure TMainForm.ClientDelta(Sender: TObject; const AText: string);
begin
  PostEvent(uekDelta, AText);
end;

procedure TMainForm.ClientDone(Sender: TObject; const AText: string);
begin
  PostEvent(uekDone, AText);
end;

procedure TMainForm.ClientError(Sender: TObject; const ACode, AMessage: string);
begin
  PostEvent(uekError, ACode, AMessage);
end;

procedure TMainForm.ClientClosed(Sender: TObject);
begin
  PostEvent(uekClosed);
end;

procedure TMainForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  if FCapture <> nil then
  begin
    FCapture.StopWav;
    FCapture.Stop;
    FreeAndNil(FCapture);
  end;
  if FClient <> nil then
  begin
    FClient.Close;
    FreeAndNil(FClient);
  end;
  FEvents.Free;
  FEvents := nil;
end;

end.
