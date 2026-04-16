# ADR 007: Hotkey Global — CGEvent tap + ActivationKeyManager (+ KeyboardShortcuts residual)

## Status

**Revisado — 2026-04-16** (ver secao "Revisao 2026-04-16" abaixo).

Originalmente: Aceito.

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

---

## Revisao 2026-04-16 — CGEvent tap + ActivationKeyManager

A decisao original foi **parcialmente revisada**. O `HotkeyManager` foi reescrito
usando `CGEvent.tapCreate` diretamente em vez de depender do `KeyboardShortcuts`
para o atalho principal de gravacao. `KeyboardShortcuts` continua sendo usado, mas
apenas para um caso secundario (ver abaixo).

### Motivacao da mudanca

`KeyboardShortcuts` e otimo para atalhos combinacao-de-teclas estilo "Cmd+Shift+R",
mas o usuario pediu funcionalidades que a lib nao cobre bem:

1. **Ativacao por modificador isolado** — ex.: "Right Command" sozinho, sem outra
   tecla. `KeyboardShortcuts` nao trata modificadoras isoladas como atalhos validos.
2. **Hold mode** (push-to-talk) — grava enquanto a tecla esta pressionada, para ao
   soltar. Exige key-down/key-up separados; o `onKeyDown`/`onKeyUp` da lib nao cobre
   bem modificadoras isoladas.
3. **Double-tap mode** — detectar duplo toque rapido de modificadora como gatilho.
4. **Cancelamento com ESC durante gravacao** — precisa interceptar ESC fora do
   contexto de um atalho registrado.

### Arquitetura atual

- `ActivationKeyManager` (`zspeak/ActivationKeyManager.swift`): modelo observavel
  que guarda a preferencia do usuario — `ActivationKey` (Right ⌘, Right ⌥, Fn,
  combinacoes como ⌥+⌘, ou `custom` recebendo shortcut completo via recorder) e
  `ActivationMode` (`toggle` / `hold` / `doubleTap`). Persiste em `UserDefaults`.
- `HotkeyManager` (`zspeak/HotkeyManager.swift`): cria um `CGEvent.tapCreate`
  global que observa `keyDown`, `keyUp` e `flagsChanged`. Decide se o evento
  atual corresponde ao `ActivationKey` selecionado (incluindo deteccao
  left-vs-right de modificadoras via keycodes 54/55, 58/61, etc.) e dispara
  callbacks `onToggle` / `onStartRecording` / `onStopRecording` /
  `onCancelRecording` conforme o `ActivationMode`.
- Event tap requer **permissao de Accessibility** (ja exigida pelo app para
  `CGEvent` paste via `TextInserter`) — zero permissao adicional.

### KeyboardShortcuts residual

`KeyboardShortcuts` continua no projeto, usado apenas para **Modo Prompt LLM**
(atalho customizavel `togglePromptMode`), onde a semantica combinacao-de-teclas
da lib funciona perfeitamente. O componente `KeyboardShortcuts.Recorder` tambem
e reutilizado na UI quando o usuario seleciona `ActivationKey.custom` para a
hotkey de gravacao, entao a dependencia continua valendo seu peso.

### Trade-offs da nova arquitetura

**Positivos:**
- Ativacao por modificadora isolada (Right ⌘ etc.) funciona de verdade
- Suporte a hold/push-to-talk + double-tap em cima da mesma base de tap
- ESC para cancelar e interceptavel sem registro extra de atalho
- Controle fino do processamento de eventos (podemos deixar o evento propagar
  ou consumir conforme o contexto)

**Negativos:**
- Requer permissao de Accessibility (ja exigida pelo paste, nao adiciona
  friccao em relacao ao estado anterior)
- Event tap e API de nivel mais baixo — mais codigo proprio para manter
- `CGEvent.tapCreate` pode ser desabilitado pelo SO em condicoes especificas
  (ex.: usuario revoga Accessibility), precisa observar e avisar na UI

### Se o event tap precisar ser revertido

- Caminho de volta e usar `KeyboardShortcuts` puro para toggle-com-combinacao
  (abandonando hold mode / double-tap / modificadora isolada como features)
- Registrar nova ADR em vez de reverter esta
