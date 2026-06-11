# ADR 006: Inserção de Texto — CGEvent + NSPasteboard

## Status
Aceito

## Contexto
Após transcrever a fala, o texto precisa ser inserido no app que está em foco (VS Code, Terminal, Slack, browser, etc.). Opções:
- **Clipboard + Cmd+V simulado** (CGEvent + NSPasteboard): Funciona em qualquer app
- **Accessibility API** (AXUIElement): Mais "correto" mas menos confiável
- **Character-by-character** (CGEvent por caractere): Lento (~100ms/char), funciona sempre
- **AppleScript**: Funciona apenas em apps com suporte a AppleScript

O Spokenly usa CGEvent + NSPasteboard.

## Decisão
Adotamos **NSPasteboard** (clipboard) + **CGEvent** (Cmd+V simulado).

## Justificativa

### Universalidade
- Funciona em qualquer app que aceite Cmd+V (virtualmente todos)
- Não depende de Accessibility API do app alvo
- Funciona com VS Code, Terminal, Slack, browser, Notes, etc.

### Implementação
```swift
// 1. Escrever texto transcrito no clipboard
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(transcribedText, forType: .string)

// 2. Delay curto para o app alvo reativar e o clipboard propagar
// 3. Simular Cmd+V via CGEvent
let source = CGEventSource(stateID: .hidSystemState)
let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // 9 = V
let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
keyDown?.flags = .maskCommand
keyDown?.post(tap: .cgAnnotatedSessionEventTap)
keyUp?.post(tap: .cgAnnotatedSessionEventTap)
```

### Requisitos
- **Sem sandbox**: CGEvent não funciona em apps sandboxed
- **Permissão de Acessibilidade**: Necessária no macOS para postar eventos de teclado
- `AXIsProcessTrustedWithOptions` para verificar/solicitar permissão

### UX
- Delay curto entre reativar app, escrever no clipboard e postar Cmd+V
- Não restaurar o clipboard anterior: se o paste automático falhar silenciosamente,
  o texto transcrito permanece disponível para Cmd+V manual

## Consequências

### Positivas
- Funciona em qualquer app
- Rápido (< 100ms total)
- Simples de implementar
- Mesmo método usado pelo Spokenly, SuperWhisper, VoiceInk, etc.

### Negativas
- Sobrescreve clipboard do usuário com o texto transcrito
- Requer permissão de Acessibilidade (prompt na primeira vez)
- Não funciona se app estiver em sandbox
- Não funciona se o app em foco não aceitar paste

### Riscos
- Race condition entre clipboard write e Cmd+V → mitigado com delay de 50ms
- Clipboard manager do usuário pode interferir no conteúdo colado

## Alternativas rejeitadas
- **Accessibility API (AXUIElement)**: Mais "correto" mas muitos apps não expõem text fields via AX. Menos confiável na prática.
- **Character-by-character**: ~100ms por caractere = 5 segundos para 50 chars. Inaceitável.
- **AppleScript**: Não funciona com a maioria dos apps modernos (Electron, etc.)
