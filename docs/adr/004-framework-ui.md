# ADR 004: Framework de UI — Swift + SwiftUI Nativo com MenuBarExtra

## Status
Aceito

## Contexto
O app precisa de uma UI mínima: ícone no tray, overlay de status, tela de configurações. Opções:
- **Swift + SwiftUI nativo**: MenuBarExtra (macOS 13+), processo único
- **Electron**: Cross-platform, React/TypeScript, ~150 MB overhead, 2 processos
- **Tauri**: Rust + WebView, ~10 MB, FluidAudio tem wrapper Rust
- **Python + tkinter/Qt**: Requer Python runtime

O Spokenly é um app Swift nativo — queremos a mesma stack.

## Decisão
Adotamos **Swift + SwiftUI nativo** com **MenuBarExtra**.

## Justificativa

### Processo único
- ASR (FluidAudio) + VAD + UI tudo no mesmo processo Swift
- Sem IPC, sem WebSocket, sem latência de comunicação entre processos
- Menos pontos de falha

### Performance
- App ocupa ~5 MB em disco (sem contar modelos)
- ~30-50 MB RAM idle
- Startup instantâneo
- Sem Chromium embutido (Electron usa ~150 MB só para o runtime)

### MenuBarExtra
- API nativa macOS 13+ para apps de tray
- Estilo `.window` para popover com SwiftUI views customizadas
- `LSUIElement = YES` esconde do Dock
- Integração perfeita com system appearance (dark/light mode)

### Acesso completo ao sistema
- AVAudioEngine para captura de áudio
- CGEvent para simular Cmd+V (requer fora do sandbox)
- NSPasteboard para clipboard
- Accessibility API
- Tudo nativo, sem bridges

### Mesma stack do Spokenly
- Spokenly é Swift nativo com SwiftUI
- Provado em produção (100k+ usuários)

## Consequências

### Positivas
- Menor footprint (disco, RAM, CPU)
- Latência mínima (processo único)
- Acesso direto a todas APIs do macOS
- Visual consistente com o sistema

### Negativas
- Somente macOS — sem Windows/Linux
- Requer conhecimento de Swift/SwiftUI
- Sem hot reload como Electron/React (preview do Xcode parcialmente compensa)
- App Store requer sandbox (CGEvent não funciona em sandbox) — distribuição fora da App Store ou com entitlements especiais

### Riscos
- Se precisar de cross-platform no futuro → FluidAudio tem wrapper Tauri/Rust
- Se Apple deprecar MenuBarExtra → improvável, mas pode migrar para NSStatusItem

## Alternativas rejeitadas
- **Electron**: ~150 MB overhead, 2 processos (IPC), mais lento. Contradiz princípio de simplicidade.
- **Tauri**: Boa alternativa (FluidAudio tem wrapper), mas adiciona Rust + WebView. Pode ser considerado no futuro para cross-platform.
- **Python + Qt**: Requer Python runtime, 2 processos, overhead de IPC.
