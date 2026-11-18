# zspeak

## Project Overview

- **App:** zspeak — transcrição por voz local para devs
- **Platform:** macOS 14+ (Sonoma), Apple Silicon (M1+)
- **Language:** Swift 6.1+, SwiftUI
- **IDE:** Xcode com Swift 6.1 ou mais recente

## Tech Stack

- **FluidAudio** v0.18.3 (Apache 2.0) — ASR via Core ML e Apple Neural Engine
- **Parakeet Ultra** — modelo de transcrição no macOS (~630 MB, PT-BR incluído)
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
- Pipeline no macOS: `Mic → AVAudioEngine → Parakeet Ultra (Core ML/ANE) → Clipboard → Cmd+V`
- Models auto-downloaded from HuggingFace on first use

## Conventions

- Language: Swift, SwiftUI
- Comentários no código em português
- Respostas e comunicação em português
- No sandbox (necessário para inserção de texto via CGEvent)
- Permissões: Microphone + Accessibility
- Versionamento: a cada alteração implementada, incrementar por padrão o último nível da versão (`1.0.3` → `1.0.4` → `1.0.5`). Só incrementar o segundo nível quando o usuário pedir explicitamente.

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
│   ├── RecordingController.swift
│   ├── LLMCoordinator.swift
│   ├── FileTranscriptionCoordinator.swift
│   ├── Transcriber.swift
│   ├── HotkeyManager.swift
│   ├── TextInserter.swift
│   └── Views/
├── docs/
│   ├── adr/    (Architecture Decision Records)
│   └── prd/    (Product Requirements)
└── AGENTS.md
```

## Key Rules

- Simplicidade é prioridade — MVP primeiro
- Mesmo stack do Spokenly (FluidAudio + CoreML)
- Modelo de transcrição único por plataforma. Parakeet Ultra no macOS e Parakeet TDT 0.6B v3 no Windows.
- 100% local — sem cloud, sem API keys
- PT-BR com termos técnicos em inglês (code-switching nativo do modelo)
