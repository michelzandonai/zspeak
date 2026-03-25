# ADR 007: Hotkey Global — KeyboardShortcuts (sindresorhus)

## Status

Aceito

## Contexto

O app precisa de um atalho de teclado global (funciona em qualquer app) para toggle de gravacao. Opcoes avaliadas:

- **KeyboardShortcuts** (sindresorhus): SwiftUI nativo, customizavel pelo usuario, App Store safe. 2.579 stars, atualizado fev/2026.
- **HotKey** (soffes): Simples, hotkey fixa. 1.070 stars, ultimo push dez/2024. Carbon APIs legacy.
- **Carbon API direto**: `RegisterEventHotKey` — funciona mas e API C legacy de 2001.
- **NSEvent.addGlobalMonitorForEvents**: Nao funciona para key combinations quando app nao tem foco.

Modo de ativacao escolhido pelo usuario: **Toggle hotkey** (pressiona para iniciar, pressiona de novo para parar).

## Decisao

Adotamos **KeyboardShortcuts** (github.com/sindresorhus/KeyboardShortcuts).

## Justificativa

### Moderno e mantido

- 2.579 stars, atualizado fevereiro 2026
- Swift 6.2, suporte a strict concurrency
- Autor: sindresorhus (um dos devs Swift open source mais prolificos)

### Customizavel pelo usuario

- Componente SwiftUI pronto para configurar atalho:
  ```swift
  KeyboardShortcuts.Recorder("Atalho de gravacao:", name: .toggleRecording)
  ```
- O usuario escolhe o atalho que quiser
- Deteccao de conflitos com atalhos do sistema
- Persiste automaticamente em UserDefaults

### App Store compatible

- Usa APIs aprovadas pela Apple
- Sem uso de private APIs
- Funciona dentro e fora do sandbox

### Toggle mode

- `onKeyDown` handler para toggle:
  ```swift
  KeyboardShortcuts.onKeyDown(for: .toggleRecording) {
      appState.toggleRecording()
  }
  ```

### Integracao SwiftUI nativa

- Componente `Recorder` para tela de settings
- Suporte a dark/light mode automatico
- Acessibilidade built-in

## Consequencias

### Positivas

- Usuario configura o atalho que preferir
- UI de configuracao pronta (Recorder component)
- Mantido ativamente, Swift moderno
- Deteccao de conflitos

### Negativas

- Dependencia de terceiros (mitigado: MIT license, codigo simples)
- Nao suporta push-to-talk nativo (key down/key up separados) — para toggle isso e irrelevante

### Riscos

- Se sindresorhus abandonar → MIT license, pode forkar. Codigo e relativamente simples.

## Alternativas rejeitadas

- **HotKey**: Funciona mas datado (Carbon legacy, Swift tools 5.0). Hotkey fixa, nao customizavel pelo usuario.
- **Carbon API direto**: Funciona mas e API de 2001, mais codigo boilerplate, sem UI de configuracao.
- **NSEvent global monitor**: Nao captura key combinations quando outro app tem foco.
