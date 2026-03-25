# ADR 008: Licenciamento e Dependências

## Status

Aceito

## Contexto

O projeto zspeak precisa definir sua política de dependências e garantir compatibilidade de licenças para potencial distribuição comercial futura.

## Decisão

Todas as dependências devem ter licenças **Apache 2.0** ou **MIT** (permissivas). Nenhuma dependência GPL/LGPL/AGPL é permitida no core do app.

## Dependências aprovadas

| Dependência | Versão | Licença | Uso | Verificado |
|---|---|---|---|---|
| **FluidAudio** | v0.12.6 | Apache 2.0 | ASR (Parakeet TDT) + VAD (Silero) | github.com/FluidInference/FluidAudio |
| **KeyboardShortcuts** | latest | MIT | Hotkey global customizável | github.com/sindresorhus/KeyboardShortcuts |
| **LaunchAtLogin** | latest | MIT | Auto-start com sistema | github.com/sindresorhus/LaunchAtLogin |

### Modelos ML

| Modelo | Licença | Origem |
|---|---|---|
| **Parakeet TDT 0.6B V3** (CoreML) | CC-BY-4.0 | FluidInference/parakeet-tdt-0.6b-v3-coreml |
| **Silero VAD** (CoreML) | MIT | FluidInference/silero-vad-coreml |

### APIs do sistema (sem licença necessária)

- AVAudioEngine, AVAudioConverter (Apple)
- CGEvent, CGEventSource (Apple)
- NSPasteboard (Apple)
- MenuBarExtra (Apple SwiftUI)

## Justificativa

### Compatibilidade comercial

- Apache 2.0 e MIT permitem uso comercial sem restrições
- CC-BY-4.0 (Parakeet TDT) exige apenas atribuição — aceitável
- Nenhuma cláusula copyleft que force abertura do nosso código

### Gestão de dependências

- Apenas 3 dependências externas via SPM — mínimo possível
- Todas mantidas ativamente (verificado março 2026)
- Todas com > 1.000 stars no GitHub
- Nenhuma dependência transitiva problemática conhecida

### Atribuição necessária

- **NVIDIA**: Atribuição pelo modelo Parakeet TDT (CC-BY-4.0)
- **FluidInference**: Manter NOTICE do Apache 2.0
- **sindresorhus**: MIT — atribuição no LICENSE file

## Consequências

### Positivas

- Livre para distribuição comercial
- Sem cláusulas copyleft
- Poucas dependências, fácil de auditar
- Todas as dependências são well-known e mantidas

### Negativas

- CC-BY-4.0 do Parakeet requer atribuição visível (about screen ou docs)
- Se precisar de dependência GPL no futuro, precisará de ADR nova

### Regras

1. Novas dependências devem ser Apache 2.0 ou MIT
2. Dependências GPL/LGPL/AGPL requerem aprovação via ADR
3. Atribuição do Parakeet TDT e FluidAudio deve estar visível no app (About ou Settings)
4. Manter arquivo THIRD_PARTY_LICENSES.md atualizado
