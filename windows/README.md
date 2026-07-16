# zspeak para Windows

Aplicativo nativo de tray para Windows 11 x64. Captura o microfone via WASAPI,
converte para PCM float32 mono 16 kHz, transcreve localmente com Parakeet TDT
0.6B V3 e envia o resultado ao aplicativo anteriormente focado com clipboard e
`Ctrl+V`.

## Privacidade e operação offline

- Não há cloud, API key, login, telemetria ou upload de áudio/texto.
- Configurações, histórico e modelo ficam em `%LOCALAPPDATA%\zspeak`.
- O primeiro uso baixa o modelo oficial (~465 MiB compactado), valida tamanho e
  SHA-256 e o extrai. O cache completo usa cerca de 1,2 GiB. Depois disso o app
  funciona sem internet.
- Áudio capturado existe somente em memória até a transcrição terminar.

## Instalação

Execute `zspeak-1.0.50-win-x64-setup.exe`. O instalador é por usuário, não pede
privilégio administrativo e instala em `%LOCALAPPDATA%\Programs\zspeak`.

Depois da abertura, procure o ícone do zspeak na bandeja. Use
`Ctrl+Alt+Espaço` para iniciar e encerrar a gravação. A janela de configurações
permite escolher o microfone e consultar o histórico local.

## Build e testes

Requer apenas o SDK .NET 8 x64; Visual Studio não é necessário.

```powershell
dotnet restore windows/ZSpeak.Windows.sln
dotnet build windows/ZSpeak.Windows.sln -c Release --no-restore
dotnet test windows/ZSpeak.Windows.sln -c Release --no-build
```

O teste `ModelFirstRunIntegrationTests` usa o archive já existente no cache para
validar download, hash e extração sem transferir 465 MiB novamente. Preencha o
cache antes com:

```powershell
dotnet run --project windows/src/ZSpeak.AsrSpike -c Release
```

Para provar a segunda execução offline:

```powershell
dotnet run --project windows/src/ZSpeak.AsrSpike -c Release -- --offline --beam
```

Para publicar e gerar o instalador (Inno Setup 6 instalado):

```powershell
windows\scripts\package.cmd
```

## Benchmark do spike

Medição em Windows 11 Pro x64 build 26200, Intel Core i7-9700K, 16 GiB RAM,
sherpa-onnx 1.13.4, CPU, `modified_beam_search`:

| Métrica | Resultado |
|---|---:|
| Carga do modelo | 3,241 s |
| Pico de memória | 838,8 MiB |
| `pt-short.wav` (2,785 s) | 0,276 s; RTF 0,0992 |
| `pt-long.wav` (13,245 s) | 1,037 s; RTF 0,0783 |

Termos confirmados após normalização local: `pipeline`, `deploy`, `Kubernetes`,
`PostgreSQL`, `cache`, `Redis` e `pull request`.

## Estrutura

- `src/ZSpeak.Core`: ASR, download/cache, normalização e persistência.
- `src/ZSpeak.Platform`: WASAPI e interop Win32.
- `src/ZSpeak.App`: WPF, tray, overlay e composição.
- `src/ZSpeak.AsrSpike`: benchmark e prova offline.
- `tests`: testes unitários e de integração.
- `installer`: definição do instalador Inno Setup.
- `scripts`: build, publish e smoke tests.

Consulte [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) para licenças e atribuições.
