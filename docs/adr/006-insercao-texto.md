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
// 1. Salvar clipboard atual (para restaurar depois)
let previousContents = NSPasteboard.general.string(forType: .string)

// 2. Escrever texto transcrito no clipboard
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(transcribedText, forType: .string)

// 3. Delay de 50ms (clipboard precisa propagar)
// 4. Simular Cmd+V via CGEvent
let source = CGEventSource(stateID: .hidSystemState)
let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) // 9 = V
let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
keyDown?.flags = .maskCommand
keyDown?.post(tap: .cgAnnotatedSessionEventTap)
keyUp?.post(tap: .cgAnnotatedSessionEventTap)

// 5. Restaurar clipboard anterior (após delay)
```

### Requisitos
- **Sem sandbox**: CGEvent não funciona em apps sandboxed
- **Permissão de Acessibilidade**: Necessária no macOS para postar eventos de teclado
- `AXIsProcessTrustedWithOptions` para verificar/solicitar permissão

### UX
- Delay de 50ms entre clipboard write e Cmd+V (necessário)
- Restaurar clipboard anterior opcionalmente (bom UX, evita perder conteúdo do usuário)
- Timeout de 200ms para restauração do clipboard

## Consequências

### Positivas
- Funciona em qualquer app
- Rápido (< 100ms total)
- Simples de implementar
- Mesmo método usado pelo Spokenly, SuperWhisper, VoiceInk, etc.

### Negativas
- Sobrescreve clipboard temporariamente (mitigado com save/restore)
- Requer permissão de Acessibilidade (prompt na primeira vez)
- Não funciona se app estiver em sandbox
- Não funciona se o app em foco não aceitar paste

### Riscos
- Race condition entre clipboard write e Cmd+V → mitigado com delay de 50ms
- Clipboard manager do usuário pode interferir → delay de restore ajustável

## Alternativas rejeitadas
- **Accessibility API (AXUIElement)**: Mais "correto" mas muitos apps não expõem text fields via AX. Menos confiável na prática.
- **Character-by-character**: ~100ms por caractere = 5 segundos para 50 chars. Inaceitável.
- **AppleScript**: Não funciona com a maioria dos apps modernos (Electron, etc.)
