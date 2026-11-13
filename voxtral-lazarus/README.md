# Voxtral Realtime — Reconnaissance vocale sous Lazarus (32 bits)

Application Windows 32 bits (Lazarus / Free Pascal) qui transcrit le micro en
temps réel avec l'API **Mistral Voxtral Realtime** :

- Capture micro Windows via **MMSystem / waveIn** (`audiocapture.pas`)
- Audio **PCM 16 kHz – Mono – 16 bits**, chunks de 100 ms (3 200 octets)
- Connexion **WebSocket** TLS vers
  `wss://api.mistral.ai/v1/audio/transcriptions/realtime?model=...`
  (`voxtralclient.pas`, client WebSocket RFC 6455 autonome, sans dépendance tierce)
- Transcription **progressive** dans un `TMemo` (événements
  `transcription.text.delta`), transcript final via `transcription.done`
- Enregistrement simultané en fichier **WAV** (case « Enregistrer WAV »)

L'interface n'utilise que les contrôles LCL standards (TPanel, TLabel, TEdit,
TComboBox, TSpinEdit, TCheckBox, TButton, TMemo) : aucun package tiers à
installer, ce qui simplifie la compilation 32 bits.

## Fichiers

| Fichier | Rôle |
|---|---|
| `voxtralrealtime.lpi` / `.lpr` | Projet Lazarus |
| `main.pas` / `main.lfm` | Fiche principale (UI) |
| `audiocapture.pas` | Capture waveIn 16 kHz mono 16 bits + écriture WAV |
| `voxtralclient.pas` | Client WebSocket TLS (handshake, trames, JSON) |

## Compilation 32 bits

1. Installer **Lazarus 32 bits** (FPC `i386-win32`) sous Windows, ou un
   Lazarus 64 bits avec le cross-compilateur `i386-win32`
   (via [fpcupdeluxe](https://github.com/newpascal/fpcupdeluxe) ou
   FPC `make all CPU_TARGET=i386 OS_TARGET=win32`).
2. Ouvrir `voxtralrealtime.lpi` dans Lazarus.
3. Cross-compilation depuis un Lazarus 64 bits : menu
   *Projet → Options du projet → Config and Target* →
   **Target OS : win32**, **Target CPU : i386**.
4. Menu *Exécuter → Construire* → génère `VoxtralRealtime.exe` (32 bits).

Vérifier l'architecture : clic droit sur l'exécutable → Propriétés →
Détails → « Type de fichier : application console 32 bits », ou
`file VoxtralRealtime.exe` (PE32).

## Exécution

1. Placer à côté de l'exécutable des **DLL OpenSSL 32 bits** :
   - `libssl-1_1.dll` + `libcrypto-1_1.dll` (recommandé), ou
   - `libeay32.dll` + `ssleay32.dll`.
   Sans elles, la connexion TLS échoue au démarrage de la session.
2. Optionnel : `cacert.pem` (bundle CA, par ex. celui de curl.se) à côté de
   l'exécutable active la **vérification du certificat serveur**. Sans ce
   fichier, la connexion est chiffrée mais le certificat n'est pas vérifié.
3. Clé API Mistral : https://console.mistral.ai (menu API keys).
4. Choisir le modèle, la langue (ou « auto »), le délai de streaming
   (80–1200 ms ou 2400 ; 480 ms recommandé), puis **Démarrer**.
   Les deltas de transcription s'ajoutent au fil de l'eau dans le memo ;
   **Arrêter** envoie `input_audio.end` et affiche le transcript final.

## Protocole implémenté

| Sens | Message |
|---|---|
| → API | `session.update` (`audio_format: pcm_s16le/16000 Hz`, `target_streaming_delay_ms`, `language`) |
| → API | `input_audio.append` (chunk PCM 100 ms encodé en base64) |
| → API | `input_audio.end` |
| ← API | `session.created`, `session.updated`, `transcription.text.delta`, `transcription.done`, `error` |

Les réglages sont figés dès le premier `input_audio.append` (contrainte API) :
la session est configurée sur `session.updated`, avant le démarrage de la
capture.
