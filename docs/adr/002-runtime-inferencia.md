# ADR 002: Runtime de Inferencia — CoreML/ANE via FluidAudio

## Status

Aceito

## Contexto

O modelo Parakeet TDT 0.6B V3 precisa de um runtime para rodar no Apple Silicon. Opcoes avaliadas:

- **FluidAudio** (Swift, CoreML/ANE): lib open source Apache 2.0, mesma usada pelo Spokenly. Auto-download de modelos. SPM.
- **parakeet-mlx** (Python, MLX/Metal): Nativa Apple Silicon via Metal GPU. Requer Python sidecar.
- **onnx-asr** (Python, ONNX Runtime): Cross-platform, CPU. RTFx 36. Requer Python sidecar.
- **NeMo** (Python, PyTorch): Framework oficial NVIDIA. Pesado, requer PyTorch completo.
- **sherpa-onnx** (C++/Swift, ONNX): Cross-platform, suporte Swift. Bom mas sem CoreML/ANE.

## Decisao

Adotamos **FluidAudio** (github.com/FluidInference/FluidAudio) com inferencia via **CoreML / Apple Neural Engine**.

## Justificativa

### Performance

- ~110x real-time no M4 Pro (1 hora de audio em ~19 segundos)
- Apple Neural Engine (ANE) e dedicado para ML — nao compete com CPU/GPU
- CoreML compilacao otimizada para hardware especifico do dispositivo

### Mesmo stack do Spokenly

- FluidAudio e a mesma lib usada pelo Spokenly em producao (100k+ usuarios)
- README do FluidAudio confirma: Spokenly e usuario
- Provado e validado em producao real
- v0.12.6, 1.741 stars, push diario, ativamente mantido

### O que vem incluso

- ASR: Parakeet TDT 0.6B v2/v3 via CoreML
- VAD: Silero VAD via CoreML
- ITN: Inverse Text Normalization (7 idiomas)
- Streaming ASR: Parakeet EOU 120M
- TTS, Speaker Diarization (nao usamos agora, mas disponivel)
- Auto-download de modelos do HuggingFace
- Modelos CoreML pre-convertidos: `FluidInference/parakeet-tdt-0.6b-v3-coreml` (164k downloads)

### Processo unico

- Swift nativo — sem Python sidecar, sem WebSocket, sem IPC
- Menor latencia possivel
- Menor consumo de memoria
- Menor complexidade de deploy

### API simples (~5 linhas)

```swift
let models = try await AsrModels.downloadAndLoad(version: .v3)
let asrManager = AsrManager(config: .default)
try await asrManager.initialize(models: models)
let result = try await asrManager.transcribe(samples)
```

### Integracao

- SPM (Swift Package Manager) e CocoaPods
- macOS 14+, iOS 17+
- Swift 6.0+, Xcode 15+

## Consequencias

### Positivas

- Performance maxima no Apple Silicon (ANE)
- Stack identica ao Spokenly
- Processo unico, sem overhead de IPC
- Biblioteca completa (ASR + VAD + ITN)
- API simples e bem documentada

### Negativas

- Exclusivo Apple Silicon — nao roda em Intel Macs
- macOS 14+ minimo
- ~1-2 GB de download no primeiro uso (modelos CoreML)
- Dependencia de terceiros (FluidInference)

### Riscos

- Se FluidAudio for abandonado → mitigado: Apache 2.0 permite fork
- Se Apple mudar CoreML API → mitigado: FluidAudio abstrai isso

## Alternativas rejeitadas

- **parakeet-mlx**: Boa performance mas requer Python sidecar (2 processos, WebSocket)
- **onnx-asr**: Simples mas roda em CPU (RTFx 36 vs ~110x no ANE)
- **sherpa-onnx**: Cross-platform mas sem CoreML/ANE optimization
- **NeMo**: Muito pesado (PyTorch completo), overkill para inferencia
