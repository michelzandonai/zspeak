# zspeak

Transcrição por voz local para devs, nativa no macOS e no Windows.

O zspeak captura o microfone, transcreve com o Parakeet TDT 0.6B V3 e insere o
texto no aplicativo que estava em foco. Áudio, texto, configurações e histórico
permanecem na máquina: não há cloud, API key, login ou telemetria.

## Plataformas

| | macOS | Windows |
|---|---|---|
| Sistema | macOS 14+, Apple Silicon | Windows 11 x64 |
| Interface | SwiftUI, menu bar e overlay | C#/.NET 8, WPF, tray e overlay |
| Captura | AVAudioEngine | NAudio/WASAPI |
| ASR | FluidAudio + CoreML/ANE | sherpa-onnx + ONNX Runtime |
| Inserção | Clipboard + `Cmd+V` | Clipboard + `Ctrl+V` |
| Modelo | Parakeet TDT 0.6B V3 | Parakeet TDT 0.6B V3 |

- [Guia do macOS](#macos)
- [Guia do Windows](windows/README.md)
- [Estado técnico do port Windows](docs/HANDOFF-WINDOWS.md)
- [Prompt pronto para sincronizar no Mac](docs/PROMPT-MAC.md)
- [Site oficial](https://michelzandonai.github.io/zspeak/)

## Como funciona

```text
Microfone -> áudio mono 16 kHz -> Parakeet TDT V3 -> Clipboard -> app em foco
```

1. Use a hotkey global para começar a gravação.
2. Fale normalmente e use a hotkey novamente para encerrar.
3. A transcrição acontece localmente.
4. O resultado é copiado e colado no aplicativo anteriormente focado.

O modelo é baixado e validado na primeira execução. Depois de armazenado no
cache local, o reconhecimento funciona offline.

## Windows

A implementação Windows está isolada em [`windows/`](windows/) e preserva o
aplicativo macOS. O P0 inclui:

- aplicativo de bandeja e overlay WPF;
- captura WASAPI em float32 mono, 16 kHz;
- hotkey global `Ctrl+Alt+Espaço`;
- transcrição local com sherpa-onnx e Parakeet TDT V3;
- restauração de foco, clipboard e envio de `Ctrl+V`;
- configurações e histórico em `%LOCALAPPDATA%\zspeak`;
- instalador Inno Setup por usuário, sem exigir Visual Studio ou .NET instalado;
- testes unitários, integração Win32, prova offline e smoke test empacotado.

Para compilar:

```powershell
dotnet restore windows/ZSpeak.Windows.sln --locked-mode
dotnet build windows/ZSpeak.Windows.sln -c Release --no-restore
dotnet test windows/ZSpeak.Windows.sln -c Release --no-build
```

Para publicar e gerar o instalador local, com Inno Setup 6 instalado:

```powershell
windows\scripts\package.cmd
```

O instalador público ainda precisa de assinatura de código antes de uma release.
Builds, modelos e caches não são commitados no repositório.

## macOS

### Requisitos

- macOS 14 Sonoma ou superior;
- Apple Silicon (M1 ou mais novo);
- Xcode 15 ou superior;
- permissões de Microfone e Acessibilidade;
- internet no primeiro uso para baixar o modelo.

### Sincronizar em outro Mac

Você não precisa baixar o modelo manualmente. Se o repositório ainda não existe:

```bash
git clone https://github.com/michelzandonai/zspeak.git
cd zspeak
```

Se já existe e não há alterações locais pendentes:

```bash
git switch main
git pull --ff-only origin main
```

Depois abra `Package.swift` no Xcode, aguarde o Swift Package Manager resolver as
dependências, selecione `My Mac` e use `Cmd+R`.

Pelo terminal:

```bash
xcodebuild -scheme zspeak -configuration Debug -destination 'platform=macOS' build
```

Na primeira captura, autorize o microfone e a Acessibilidade em
`System Settings -> Privacy & Security`. O app baixa o modelo de ASR pelo
FluidAudio e o mantém em cache para os próximos usos offline.

### Recursos atuais do macOS

- hotkey global nos modos `Toggle`, `Hold` e `Double Tap`;
- seleção e prioridade de microfones;
- Prompt Mode com LLM local opcional;
- transcrição de arquivos e histórico local;
- inicialização com o sistema;
- cancelamento da gravação com `Esc`, quando habilitado.

Para empacotar localmente:

```bash
scripts/package_app.sh
```

Uma distribuição pública para macOS exige identidade Developer ID e
notarização. O script aceita `SIGNING_IDENTITY`; sem ela, usa uma identidade
autoassinada apenas para desenvolvimento local.

## Benchmark Windows

Medição em Windows 11 Pro x64, Intel Core i7-9700K, 16 GiB RAM, sherpa-onnx
1.13.4 em CPU com `modified_beam_search`:

| Métrica | Resultado |
|---|---:|
| Carga do modelo | 3,241 s |
| Pico de memória | 838,8 MiB |
| Áudio curto, 2,785 s | 0,276 s; RTF 0,0992 |
| Áudio longo, 13,245 s | 1,037 s; RTF 0,0783 |

Os testes confirmaram PT-BR e os termos `pipeline`, `deploy`, `Kubernetes`,
`PostgreSQL`, `cache`, `Redis` e `pull request`.

## Estrutura

```text
zspeak/
├── zspeak/                 # aplicativo macOS existente
├── windows/                # aplicativo Windows independente
├── Tests/                  # testes e fixtures do macOS
├── docs/                   # decisões, handoffs e guias
├── site/                   # site estático oficial
├── scripts/                # empacotamento macOS
├── Package.swift
└── AGENTS.md
```

## Privacidade

- nenhuma cloud, API key, conta ou telemetria;
- nenhum upload de áudio ou texto;
- áudio de gravação mantido somente em memória no fluxo Windows;
- modelo, preferências e histórico armazenados localmente;
- funcionamento offline depois do primeiro download do modelo.

As dependências e licenças do Windows estão documentadas em
[`windows/THIRD-PARTY-NOTICES.md`](windows/THIRD-PARTY-NOTICES.md).
