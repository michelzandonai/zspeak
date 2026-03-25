# zspeak

## Project Overview

- **App:** zspeak — transcrição por voz local para devs
- **Platform:** macOS 14+ (Sonoma), Apple Silicon (M1+)
- **Language:** Swift 6.0+, SwiftUI
- **IDE:** Xcode 15+

## Tech Stack

- **FluidAudio** v0.12.6 (Apache 2.0) — ASR + VAD via CoreML/Apple Neural Engine
- **Parakeet TDT 0.6B V3** — modelo de transcrição (~496 MB, 25 idiomas, PT-BR incluído)
- **Silero VAD** — detecção de atividade vocal via CoreML
- **AVAudioEngine** — captura de áudio nativa (16kHz mono float32)
- **CGEvent + NSPasteboard** — inserção de texto no app ativo
- **KeyboardShortcuts** (sindresorhus) — hotkey global customizável
- **LaunchAtLogin** — auto-start com sistema

## Dependencies (SPM)

| Package | URL |
|---------|-----|
| FluidAudio | https://github.com/FluidInference/FluidAudio |
| KeyboardShortcuts | https://github.com/sindresorhus/KeyboardShortcuts |
| LaunchAtLogin | https://github.com/sindresorhus/LaunchAtLogin |

## Architecture

- Single process — no sidecar, no WebSocket, no IPC
- MenuBarExtra (tray app, hidden from Dock)
- Pipeline: `Mic → AVAudioEngine → Silero VAD → Parakeet TDT (CoreML/ANE) → Clipboard → Cmd+V`
- Models auto-downloaded from HuggingFace on first use

## Conventions

- Language: Swift, SwiftUI
- Comentários no código em português
- Respostas e comunicação em português
- No sandbox (necessário para inserção de texto via CGEvent)
- Permissões: Microphone + Accessibility

## Build Commands

```bash
# Build
xcodebuild -scheme zspeak -configuration Debug build

# Run
# Abrir no Xcode → Cmd+R

# Clean
xcodebuild clean
```

## Project Structure

```
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
│   ├── adr/    (Architecture Decision Records)
│   └── prd/    (Product Requirements)
└── CLAUDE.md
```

## Key Rules

- Simplicidade é prioridade — MVP primeiro
- Mesmo stack do Spokenly (FluidAudio + CoreML)
- Só Parakeet TDT v3 por enquanto (sem multi-modelo)
- 100% local — sem cloud, sem API keys
- PT-BR com termos técnicos em inglês (code-switching nativo do modelo)
