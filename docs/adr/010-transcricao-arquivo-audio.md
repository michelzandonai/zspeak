# ADR 010: Transcrição de arquivos de áudio com diarização opcional

## Status

Aceito

## Contexto

O zspeak hoje só transcreve áudio capturado em tempo real do microfone. Usuários precisam transcrever arquivos de áudio externos — especialmente áudios recebidos no WhatsApp (formato Opus/Ogg), gravações de reuniões antigas e podcasts. Dois problemas técnicos precisam ser resolvidos:

1. **Cobertura de formatos:** `AVAudioFile` (base do `FluidAudio.AudioConverter.resampleAudioFile`) suporta WAV, MP3, M4A, AAC, FLAC, AIFF e CAF nativamente. Não suporta **Opus/Ogg** (WhatsApp), **WMA**, **AMR** ou outros formatos menos comuns.
2. **Identificação de interlocutores:** Em áudios de reunião, o usuário quer distinguir quem está falando em cada momento, mas o Parakeet TDT v3 só faz ASR, não diarização.

Precisamos decidir como cobrir formatos não-nativos e como adicionar diarização.

## Decisão

### 1. Decodificação universal via ffmpeg embutido

Embutir o binário **ffmpeg arm64** (martin-riedl.de, pré-assinado, ~35-40 MB, LGPL 2.1+) dentro do bundle `.app` em `Contents/MacOS/ffmpeg`. Transcodar para WAV 16 kHz mono PCM antes de passar pro pipeline do FluidAudio.

Fluxo:
- Extensão está em `supportedNativeExtensions` (`wav`, `mp3`, `m4a`, `aac`, `flac`, `aif`, `aiff`, `caf`) → pula ffmpeg, lê direto com `AudioConverter.resampleAudioFile`
- Extensão é outra (`opus`, `ogg`, `wma`, `amr`, `3gp`, `mka`, `webm`, `oga`) → chama ffmpeg para transcodar para WAV temp em `NSTemporaryDirectory()` → lê o WAV com `AudioConverter.resampleAudioFile`

Comando ffmpeg:
```
ffmpeg -i {input} -ar 16000 -ac 1 -c:a pcm_s16le -fflags +discardcorrupt -y {output.wav}
```

### 2. Diarização via OfflineDiarizerManager do FluidAudio

Usar o `OfflineDiarizerManager` já incluído no FluidAudio v0.12.6 que já usamos para ASR. Modelos: `FluidInference/speaker-diarization-coreml` no HuggingFace (~600 MB, segmentation pyannote 3.1 + WeSpeaker embedding + FBank + PLDA).

**Download lazy:** os modelos só são baixados quando o usuário escolhe o modo "Reunião" pela primeira vez. Progresso mostrado na UI.

### 3. Estratégia diarize-then-transcribe para combinar ASR + Diarização

O `AsrManager` do FluidAudio expõe apenas timestamps **token-level (subword)**, não word-level, o que inviabiliza o alinhamento de palavras transcritas a segmentos de speaker via timestamps. Em vez disso:

1. Rodar diarização no áudio completo → obter `[TimedSpeakerSegment]` com `startTimeSeconds` e `endTimeSeconds`
2. Para cada segmento, extrair `samples[startTimeSeconds * 16000..<endTimeSeconds * 16000]`
3. Transcrever cada slice individualmente via `asrManager.transcribe(slice)`
4. Montar o resultado final como `[(speakerId, startTime, endTime, text)]`

## Justificativa

### ffmpeg vs libopus vs VLCKit

| Opção | Cobertura | Tamanho | Licença | Trabalho |
|---|---|---|---|---|
| **ffmpeg (martin-riedl)** | Qualquer codec/container | ~35 MB | LGPL 2.1+ | Process + Bash |
| libopus + wrapper Swift | Só Opus/Ogg | ~8 MB | BSD | Integração manual do container Ogg |
| VLCKit | Qualquer | ~50-80 MB | LGPL 2.1+ | Framework pesado |
| AudioToolbox (nativo) | WAV/MP3/M4A/FLAC/AIFF | 0 MB | Apple | Não cobre Opus |

ffmpeg ganha por **cobertura total** (resolve WhatsApp + qualquer formato futuro que o usuário jogar no app) com peso aceitável (modelo Parakeet já é 496 MB em runtime). Martin-riedl.de fornece builds arm64 nativos pré-assinados, simplificando notarização.

### OfflineDiarizerManager do FluidAudio

Zero dependência nova — o `OfflineDiarizerManager` já vem no SDK que usamos desde o MVP. API é simples (3 linhas: init, `prepareModels()`, `process(audio:)`). DER 17.7% no AMI dataset é competitivo. RTFx ~70-100x offline (muito rápido). Usa ANE via CoreML. Licença do SDK é Apache 2.0.

### Diarize-then-transcribe

Alternativas consideradas:
- **Transcrever tudo + alinhar palavras a segmentos:** requer word-level timestamps, que o Parakeet TDT não expõe via API pública (só token-level subword).
- **DTW (Dynamic Time Warping) para alinhar texto a áudio:** complexo e frágil.
- **Separação de canais por speaker antes do ASR:** requer beamforming, fora do escopo.

Diarize-then-transcribe é a mais simples e usa apenas APIs públicas estáveis. Custo: cada segmento é uma chamada independente ao ASR (tipicamente 20-60 chamadas num áudio de 1h), aceitável dado o RTFx alto.

## Consequências

### Positivas

- **Cobertura total de formatos** — WhatsApp, podcasts, gravações antigas, qualquer coisa que o usuário jogue no app
- **Diarização sem dependência nova** — aproveita o que já está no FluidAudio
- **Lazy loading** — modelos de diarização só são baixados se o usuário usar o modo Reunião
- **Reutiliza pipeline existente** — `Transcriber.transcribe`, `TranscriptionStore.addRecord`, `AppState.applyVocabulary` funcionam sem modificação
- **Histórico integrado** — arquivos transcritos aparecem junto com gravações do microfone, inclusive para aplicar prompts LLM a posteriori

### Negativas

- **+35 MB no DMG** — ffmpeg embutido aumenta o bundle
- **+600 MB em disco (opcional)** — modelos de diarização ficam cacheados após primeira execução do modo Reunião
- **Pico de memória ~1.5 GB na primeira carga** do diarizer (compilação CoreML)
- **Notarização mais complexa** — `package_app.sh` precisa re-assinar o ffmpeg com `--options runtime` antes do codesign do app
- **Cada segmento do modo Reunião é uma chamada ASR separada** — latência total proporcional ao número de segmentos (mitigado pelo RTFx alto)

### Riscos

#### R1: Licença dos modelos de diarização

Os modelos base são `pyannote/speaker-diarization-3.1`, que no HuggingFace tem licença gated com cláusulas não-comerciais. O repo `FluidInference/speaker-diarization-coreml` repacka esses modelos em formato CoreML — precisa confirmar a licença final.

**Mitigação:**
- Validar a licença antes de shippar
- Se for non-commercial, adicionar disclaimer explícito na UI do modo Reunião ("Uso pessoal apenas — modelos pyannote sob licença não-comercial")
- zspeak hoje não é comercial (projeto pessoal / open-source), então é aceitável

#### R2: ffmpeg falha em notarização

Binários externos no bundle precisam ser assinados individualmente ANTES do `codesign --deep` do app. Se o assinamento falhar, o app não roda.

**Mitigação:** `package_app.sh` remove a assinatura original do ffmpeg martin-riedl e re-assina com o Developer ID do zspeak + `--options runtime`. Testar `codesign --verify --deep --strict` antes de gerar o DMG.

#### R3: Áudios muito longos consomem memória

Áudios de horas podem ter milhares de samples Float (8h × 16 kHz × 4 bytes ≈ 1.8 GB só do array de Float). O `resampleAudioFile` do FluidAudio já faz leitura em chunks, mas o array final ainda é materializado.

**Mitigação:** Documentar limite prático de ~2h por arquivo. Follow-up: chunking manual com overlap para arquivos maiores.

## Alternativas rejeitadas

### A1: Aceitar apenas formatos nativos e orientar usuário a converter manualmente

Mais simples, sem ffmpeg, zero trabalho extra. **Rejeitado** porque o usuário explicitou que quer transcrever áudios do WhatsApp (Opus/Ogg) sem fricção — conversão manual via Terminal/Automator é UX ruim.

### A2: libopus via SPM (swift-opus ou similar)

Resolve apenas `.opus` nativo (sem container Ogg). **Rejeitado** porque WhatsApp entrega Opus dentro de Ogg, e implementar o demuxer Ogg manualmente é complexo. Além disso não cobriria `.wma`, `.amr` e outros formatos futuros.

### A3: VLCKit

Cobertura total via libVLC. **Rejeitado** por ser enorme (50-80 MB) e overkill para o caso de uso. Framework complexo introduz mais superfície de code-signing e notarização.

### A4: Whisper ou outro modelo ASR com word-level timestamps

Permitiria alinhamento palavra-a-segmento de speaker. **Rejeitado** porque trocar o modelo ASR é fora do escopo — Parakeet TDT v3 já é a escolha do MVP (ADR-001) e muda drasticamente performance/tamanho/pipeline. Diarize-then-transcribe é suficiente com o modelo atual.

### A5: Speaker diarization via pyannote.audio Python sidecar

Rodar pyannote.audio em Python como sidecar process. **Rejeitado** porque viola o princípio de processo único (ADR-002) e adiciona Python como runtime obrigatório. O `OfflineDiarizerManager` do FluidAudio resolve sem sidecar.

## Referências

- `AudioConverter.resampleAudioFile` em `.build/checkouts/FluidAudio/Sources/FluidAudio/Shared/AudioConverter.swift:91`
- `OfflineDiarizerManager` em `.build/checkouts/FluidAudio/Sources/FluidAudio/Diarizer/Offline/Core/OfflineDiarizerManager.swift`
- Builds ffmpeg arm64: https://ffmpeg.martin-riedl.de/
- Repo de modelos de diarização: `FluidInference/speaker-diarization-coreml` no HuggingFace
- ADR 001: Modelo de Transcrição (Parakeet TDT v3)
- ADR 002: Runtime de Inferência (FluidAudio CoreML/ANE)
- ADR 008: Licenciamento de Dependências
- TASK-002: Implementação desta feature
