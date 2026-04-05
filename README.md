# zspeak

Transcrição por voz local para macOS, feita para devs.

## O que é

- App de menu bar, sem Dock
- 100% local, sem cloud e sem API keys
- Pipeline: `Mic -> AVAudioEngine -> Silero VAD -> Parakeet TDT v3 -> Clipboard -> Cmd+V`
- Modelos baixados automaticamente na primeira execução

## Requisitos

- macOS 14 Sonoma ou superior
- Apple Silicon (M1 ou mais novo)
- Xcode 15 ou superior
- Permissão de Microfone
- Permissão de Acessibilidade
- Internet na primeira execução para baixar os modelos

## Como subir em outro Mac

Você **não precisa baixar os modelos manualmente antes**.

O fluxo normal é este:

1. Fazer `git pull` no outro Mac
2. Abrir o projeto no Xcode
3. Rodar o app pela primeira vez
4. Deixar o app baixar os modelos automaticamente

Se o repositório já estiver clonado nesse Mac:

```bash
git pull
```

Depois:

1. Abra o `Package.swift` no Xcode
2. Aguarde o Swift Package Manager resolver as dependências
3. Selecione `My Mac`
4. Rode com `Cmd + R`

Se preferir pelo terminal:

```bash
xcodebuild -scheme zspeak -configuration Debug -destination 'platform=macOS' build
```

## O que é baixado automaticamente

Na primeira execução, o app baixa sozinho:

- Dependências do Swift Package Manager, quando o Xcode abrir o projeto
- Modelo de transcrição `Parakeet TDT 0.6B V3` via `FluidAudio`
- Modelo de VAD `Silero VAD` via `FluidAudio`

Isso significa que:

- Você não precisa baixar o modelo em separado
- Você precisa estar com internet no primeiro uso
- Depois disso, os modelos ficam em cache local no Mac

## Primeiro uso

Na primeira vez que abrir e começar a gravar, o macOS pode pedir:

- Acesso ao microfone
- Acesso à Acessibilidade

Essas permissões são obrigatórias para:

- Capturar o áudio
- Inserir o texto transcrito no app ativo
- Monitorar a hotkey global

Se alguma janela de permissão não aparecer, ative manualmente em:

`System Settings -> Privacy & Security -> Microphone`

`System Settings -> Privacy & Security -> Accessibility`

Se o app ainda estiver carregando os modelos, ele pode levar um pouco mais na primeira abertura. Isso é esperado.

## Uso

1. O app fica apenas na menu bar
2. Escolha a hotkey em `Configurações`
3. Inicie a gravação
4. Fale normalmente
5. Ao parar, o texto é transcrito localmente e colado no app ativo

`Esc` pode cancelar a gravação, se essa opção estiver ativa nas configurações.

## Configurações principais

- Hotkey global com modos `Toggle`, `Hold` e `Double Tap`
- Seleção de microfone
- Ordem de prioridade dos microfones conectados
- `Iniciar com o sistema`
- `Use Escape to cancel recording`

## Modelo e processamento

- ASR: `Parakeet TDT 0.6B V3`
- VAD: `Silero VAD`
- Execução local via `FluidAudio`
- Download inicial do modelo de ASR: cerca de 496 MB

## Build

```bash
xcodebuild -scheme zspeak -configuration Debug -destination 'platform=macOS' build
```

## Estrutura

```text
zspeak/
├── zspeak/
│   ├── App.swift
│   ├── AppState.swift
│   ├── AudioCapture.swift
│   ├── Transcriber.swift
│   ├── VADManager.swift
│   ├── HotkeyManager.swift
│   ├── TextInserter.swift
│   └── Views/
├── docs/
│   ├── adr/
│   └── prd/
└── AGENTS.md
```

## Observação

Para uso local em desenvolvimento, basta clonar, abrir no Xcode e rodar.
Se a ideia for distribuir para outras pessoas fora do seu ambiente, ainda vai ser preciso tratar assinatura e notarização do app.
