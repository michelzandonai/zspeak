# Melhores Práticas: Accessibility API em macOS

## 1. AXIsProcessTrusted vs AXIsProcessTrustedWithOptions

### AXIsProcessTrusted()
- **Uso**: Verificação silenciosa se a app já tem permissão
- **Retorno**: Booleano direto
- **Quando usar**: Validações internas, checks de runtime
- **Não mostra diálogo**

### AXIsProcessTrustedWithOptions()
- **Uso**: Verificação com possibilidade de solicitar permissão
- **Retorno**: Booleano + possível diálogo do sistema
- **Quando usar**: First-run setup, quando precisa de permissão garantida
- **Com `kAXTrustedCheckOptionPrompt: true`**: Mostra diálogo nativo do macOS

### Padrão Recomendado

```swift
import ApplicationServices

// 1. Verificar silenciosamente
if AXIsProcessTrusted() {
    // Já tem permissão, usar APIs normalmente
    return
}

// 2. Solicitar com diálogo nativo
let options: NSDictionary = [
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
]
let granted = AXIsProcessTrustedWithOptions(options)
if granted {
    // Usuário concedeu na janela de sistema
} else {
    // Usuário negou ou cancelou
    // Direcionar para System Settings manualmente
}
```

---

## 2. kAXTrustedCheckOptionPrompt - Comportamento

### Comportamento Exato
- **Primeira vez**: Mostra diálogo do sistema ("zspeak would like to control this computer using accessibility features")
- **Frequência**: Apenas UMA VEZ por app, por privacidade do macOS
- **Depois disso**: Retorna `false` silenciosamente (usuário já respondeu)
- **Mudanças**: Se usuário remover da lista de Accessibility, próxima chamada mostra diálogo novamente

### Diálogo Nativo
```
┌─────────────────────────────────────────┐
│ "System Preferences" Security Alert      │
├─────────────────────────────────────────┤
│                                         │
│ "zspeak" would like to control this     │
│ computer using accessibility features.  │
│                                         │
│ [Cancel]                    [OK]        │
└─────────────────────────────────────────┘
```

- Abre System Preferences se clicar [OK]
- Usuário precisa marcar checkbox manualmente
- App **NÃO** ganha permissão automaticamente

---

## 3. Detectando Permissão Concedida APÓS App Já Estar Rodando

### O Problema
- Não há notificação nativa do macOS quando permissão é concedida
- `DistributedNotificationCenter` não tem evento para isso
- Necessário implementar polling ou verificação periódica

### Soluções Implementadas em Apps Reais

#### Opção 1: Health Check Periódico (Recomendado)
```swift
import Foundation

class AccessibilityManager {
    private var checkTimer: Timer?
    private let checkInterval: TimeInterval = 1.0 // Verificar a cada 1s

    func startMonitoring() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: checkInterval, repeats: true) { [weak self] _ in
            self?.checkAccessibilityStatus()
        }
    }

    func stopMonitoring() {
        checkTimer?.invalidate()
        checkTimer = nil
    }

    private func checkAccessibilityStatus() {
        let hasPermission = AXIsProcessTrusted()
        if hasPermission && !previouslyHadPermission {
            // Permissão foi CONCEDIDA agora
            previouslyHadPermission = true
            NotificationCenter.default.post(name: NSNotification.Name("AccessibilityPermissionGranted"), object: nil)

            // Tentar criar tap ou iniciar recursos
            setupAccessibilityFeatures()
        } else if !hasPermission && previouslyHadPermission {
            // Permissão foi REVOGADA
            previouslyHadPermission = false
            NotificationCenter.default.post(name: NSNotification.Name("AccessibilityPermissionRevoked"), object: nil)
            teardownAccessibilityFeatures()
        }
    }
}
```

#### Opção 2: Verificação Lazy (Quando Necessário)
```swift
func startRecording() {
    if !AXIsProcessTrusted() {
        // Pedir permissão
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ]
        let granted = AXIsProcessTrustedWithOptions(options)

        if !granted {
            showAlert("Permissão necessária", "Abra System Settings > Privacy & Security > Accessibility")
            return
        }
    }

    // Prosseguir com gravação
}
```

#### Opção 3: Verificação ao Ganhar Focus
```swift
@main
struct ZspeakApp: App {
    @StateObject var appDelegate = AppDelegate()

    var body: some Scene {
        MenuBarExtra("zspeak", systemImage: "waveform.circle") {
            MenuBarView()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            appDelegate.checkAccessibility()
        }
    }
}
```

---

## 4. CGEvent Tap Invalidation

### Quando o Tap É Invalidado

1. **Permissão revogada**: Usuário remove app de Accessibility
2. **Timeout**: Sistema desabilita tap por inatividade (muito raro em apps bem-escritas)
3. **User input**: Usuário força desabilitação (tb raro)
4. **Re-signing da app**: Tap pode ficar "fantasma" (existe mas não recebe eventos)
5. **Code signature mismatch**: Mismatch entre código assinado e executado

### Detecção Confiável

```swift
import CoreGraphics

class HotkeyManager {
    private var eventTap: CFMachPort?
    private var tapIsValid = false

    func createEventTap() -> Bool {
        // 1. SEMPRE verificar acessibilidade ANTES de criar tap
        guard AXIsProcessTrusted() else {
            print("Sem permissão de Accessibility")
            return false
        }

        // 2. Preflight: verificar se podemos listen eventos
        guard CGPreflightListenEventAccess() else {
            print("Input Monitoring permission not granted")
            return false
        }

        // 3. Criar o tap
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                 (1 << CGEventType.flagsChanged.rawValue)

        var userInfo = TapUserInfo()
        let opaqueSelf = Unmanaged.passUnretained(&userInfo).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidTapPreInsertEvent,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: opaqueSelf
        ) else {
            print("Falha ao criar event tap")
            return false
        }

        // 4. Verificar validade IMEDIATAMENTE após criação
        if !CGEvent.tapIsEnabled(tap: tap) {
            CFRelease(tap)
            print("Tap criado mas já inválido (code signature mismatch?)")
            return false
        }

        self.eventTap = tap
        self.tapIsValid = true

        // 5. Adicionar à run loop
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CFRelease(runLoopSource)

        return true
    }

    func isTapHealthy() -> Bool {
        guard let tap = eventTap, tapIsValid else {
            return false
        }

        // Verificar se tap está realmente habilitado
        let isEnabled = CGEvent.tapIsEnabled(tap: tap)

        if !isEnabled {
            tapIsValid = false
            print("Tap foi invalidado pelo sistema")
        }

        return isEnabled
    }

    func recreateTapIfNeeded() -> Bool {
        if !isTapHealthy() {
            print("Recreando tap...")
            destroyEventTap()
            return createEventTap()
        }
        return true
    }

    private func destroyEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFRelease(tap)
        }
        eventTap = nil
        tapIsValid = false
    }
}

// Callback do event tap
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // Se tap foi desabilitado, tentar recriar
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Signal para recrear tap
        if let userInfo = userInfo {
            let managerPtr = Unmanaged<HotkeyManager>.fromOpaque(userInfo)
            managerPtr.takeUnretainedValue().recreateTapIfNeeded()
        }
    }

    // Processar evento normalmente
    return Unmanaged.passUnretained(event)
}
```

---

## 5. Problemas em macOS 14 (Sonoma) e macOS 15 (Sequoia)

### macOS 14 (Sonoma)
- **Primeira mudança**: Permissões de Accessibility mais estritas (TCC enforcement)
- **Comportamento consistente**: Event taps funcionam se permissão está explícita
- **Assinatura código**: Importância crescente de proper code signing

### macOS 15 (Sequoia) - Mudanças Críticas
- **CGEventTap falha em background apps**: Se `NSApplicationActivationPolicyProhibited`, `CGPreflightListenEventAccess()` retorna `false`
- **Workaround**: Usar `NSApplicationActivationPolicyAccessory` (permite MenuBarExtra sem interferência)
- **Input Monitoring vs Accessibility**: Dois privilégios separados agora:
  - `CGEvent.tapCreate` → Input Monitoring (mais permissivo)
  - `CGEvent.post` → Accessibility (mais restritivo)

### Recomendações para Compatibilidade

```swift
import AppKit

@main
struct ZspeakApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // IMPORTANTE: Use Accessory policy, não Prohibited
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("zspeak", systemImage: "waveform.circle") {
            MenuBarView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Verificar capabilities do sistema
        let canListen = CGPreflightListenEventAccess()
        let canPost = CGPreflightPostEventAccess()

        if !canListen || !canPost {
            print("⚠️ Accessibility/Input Monitoring não disponível")
        }
    }
}
```

---

## 6. Padrões em Apps Reais

### Raycast
- Combina KeyboardShortcuts + Accessibility permissão
- Detecta mudança via polling (check a cada app activation)
- Suporta múltiplos hotkeys com presets
- Usa MenuBarExtra com NSApplicationActivationPolicyAccessory

### Karabiner Elements
- Implementa seu próprio event tap em C++
- Health check contínuo (tap validity)
- Persistence de hotkeys via JSON
- Recriar tap após qualquer mudança de permissão
- Suporta Sequoia com ajustes específicos

### Hammerspoon
- Event tap robusto com Lua scripting
- Monitoramento ativo de tap validity
- Recreação automática on demand
- Usa DistributedNotificationCenter para app-specific events

---

## 7. Thread Safety de CGEvent

### Regras Principais

1. **CGEvent.tapCreate**: Deve ser chamado da main thread
2. **Callback do tap**: Executado em thread especial (não main)
3. **CGEvent.post**: Thread-safe, pode chamar de qualquer thread
4. **RunLoop requirements**: Tap precisa estar adicionado a um RunLoop

### Implementação Segura

```swift
import CoreGraphics

class ThreadSafeHotkeyManager {
    private let queue = DispatchQueue(label: "com.zspeak.hotkey")

    func createTapOnMainThread() {
        DispatchQueue.main.async {
            // CGEvent.tapCreate DEVE estar na main thread
            self.internalCreateTap()
        }
    }

    func postEventFromAnyThread(event: CGEvent) {
        // CGEvent.post é thread-safe
        CGEvent.post(tapLocation: .cghidEventTap, event: event)
    }

    private func internalCreateTap() {
        // Seguro chamar CGEvent.tapCreate aqui
        guard let tap = CGEvent.tapCreate(
            tap: .cghidTapPreInsertEvent,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: 1 << CGEventType.keyDown.rawValue,
            callback: { _, _, _, _ in Unmanaged.passUnretained(CGEvent()).retain() },
            userInfo: nil
        ) else {
            return
        }

        // Adicionar à main RunLoop
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CFRelease(source)
        CFRelease(tap)
    }
}
```

---

## 8. Entitlements vs Sandbox vs Accessibility

### Matriz de Capacidades

| Operação | Sandbox | Entitlement | Permissão TCC | Reqs |
|----------|---------|-------------|---------------|------|
| CGEvent.tapCreate (Listen) | ✓ (10.15+) | Não | Input Monitoring | CGPreflightListenEventAccess() |
| CGEvent.post (Cmd+V) | ✓ (10.15+) | Não | Accessibility | CGPreflightPostEventAccess() |
| NSEvent.addGlobalMonitor | ✗ | Não | Accessibility | AXIsProcessTrusted() |
| Outras Accessibility APIs | ✗ | Sim | Accessibility | AXIsProcessTrusted() |

### Configuração para zspeak (Não-Sandboxed)

**Info.plist**:
```xml
<key>NSAccessibilityUsageDescription</key>
<string>zspeak precisa de acesso de acessibilidade para capturar hotkeys globais e inserir texto transcrito no app ativo.</string>

<key>NSInputMonitoringUsageDescription</key>
<string>zspeak precisa monitorar entrada para detectar hotkey de ativação.</string>
```

**Entitlements.plist** (se necessário no futuro):
```xml
<key>com.apple.security.temporary-exception.sbpl</key>
<array>
  <!-- Não necessário para CGEvent, mas pode ser útil para outras APIs -->
</array>
```

**Build Settings (Xcode)**:
- Code Sign Identity: Apple Development / Developer ID
- Hardened Runtime: ON
- Disable Library Validation: OFF

---

## 9. Sandbox vs Sem Sandbox - Impacto em Accessibility

### Sem Sandbox (Atual - zspeak)

**Vantagens:**
- Suporta todas as Accessibility APIs sem restrição
- CGEvent.tapCreate + CGEvent.post funcionam perfeitamente
- Maior compatibilidade com apps legados
- Sem necessidade de entitlements especiais

**Desvantagens:**
- Não pode distribuir na Mac App Store
- Menos confiança do usuário (permite muito acesso)
- Verificação de assinatura mais importante

### Com Sandbox

**Vantagens:**
- Mac App Store elegível
- Mais confiável para usuário
- APIs bem-definidas

**Desvantagens:**
- CGEvent.tapCreate só funciona com Input Monitoring privilege
- NSEvent.addGlobalMonitor bloqueado
- Muitas Accessibility APIs não funciona em sandbox

**Conclusão:** Para zspeak, **NOT sandbox** é a abordagem correta.

---

## Checklist de Implementação Robusta

- [ ] Usar `AXIsProcessTrustedWithOptions` no primeiro uso
- [ ] Health check periódico a cada 1-2s
- [ ] Verificar `CGEvent.tapIsEnabled()` após criar tap
- [ ] Implementar recreação automática de tap
- [ ] Usar `NSApplicationActivationPolicyAccessory` (não Prohibited)
- [ ] Verificar `CGPreflightListenEventAccess()` antes de criar tap
- [ ] Code signing válido com Apple Developer ID ou Development
- [ ] Declarar `NSAccessibilityUsageDescription` em Info.plist
- [ ] Testar em Sonoma 14.7+ e Sequoia 15.1+
- [ ] Threads: tap criado na main thread, callback em contexto especial
- [ ] Monitorar mudanças de permissão (polling ou app focus)

---

## Referências

- [AXIsProcessTrusted - Apple Developer](https://developer.apple.com/documentation/applicationservices/1460720-axisprocesstrusted)
- [AXIsProcessTrustedWithOptions - Apple Developer](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [CGEvent.tapCreate - Apple Developer](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate)
- [CGPreflightListenEventAccess - Apple Developer](https://developer.apple.com/documentation/coregraphics/cgpreflightlisteneventaccess)
- [EventTapper GitHub - Implementation Reference](https://github.com/usagimaru/EventTapper)
- [Accessibility Permission in macOS - jano.dev](https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html)
- [CGEvent Taps and Code Signing - Daniel Raffel](https://danielraffel.me/til/2026/02/19/cgevent-taps-and-code-signing-the-silent-disable-race/)
- [Problem with event tap permission in Sequoia - Apple Developer Forums](https://developer.apple.com/forums/thread/758554)
