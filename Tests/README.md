# zspeak — Testes

Resumo dos suites e como executá-los localmente e em CI.

## Suites

| Suite                                    | Tipo         | Dependências             | Duração |
| ---------------------------------------- | ------------ | ------------------------ | ------- |
| `AppStateTests`, `IntegrationTests`, ... | Unitário     | Nenhuma                  | <5s     |
| `AudioCaptureTests` (hardware)           | Unitário*    | Permissão de microfone   | ~1s     |
| `VisualSnapshotTests`                    | Snapshot     | PNGs em `__Snapshots__/` | ~2s     |
| `TranscriberIntegrationTests`            | Integração   | Modelo Parakeet (~496MB) | 1-10min |

\* Alguns testes de hardware se auto-pulam em CI via `ProcessInfo.processInfo.environment["CI"]`.

---

## Comandos

### Rodar tudo menos integração lenta (recomendado dia-a-dia)

```bash
ZSPEAK_SKIP_SLOW=1 swift test --no-parallel
```

Use `--no-parallel` explicitamente: suítes de AppKit e preferências compartilham
estado global, e o runner Swift Testing pode paralelizá-las quando o flag é omitido.

### Rodar só os rápidos (exclui o suite lento por nome)

```bash
swift test --skip "Transcriber Integration"
```

### Rodar tudo, incluindo integração com modelo real

```bash
swift test
```

Primeira execução: baixa ~496 MB do HuggingFace (modelo Parakeet TDT v3).
Execuções seguintes: cache em `~/Library/Application Support/zspeak/Models/`.

### Rodar só o suite de integração

```bash
swift test --filter "Transcriber Integration"
```

### Rodar um único teste

```bash
swift test --filter "pt-short.wav contém"
```

### Regressão de conexão e troca de microfone (AirPods)

```bash
ZSPEAK_SKIP_SLOW=1 swift test --filter 'AudioCaptureDeviceChangeTests|RecordingControllerTests|MicrophoneManagerTests|PreRollBufferTests'
```

Os testes simulam troca do dispositivo padrão, pre-roll sem áudio recente,
interrupção durante a captura e reconexão. Exercitam o pipeline real com I/O
injetado, sem trocar o dispositivo padrão do Mac. O reteste físico complementar
é conectar, retirar e recolocar os AirPods com o app aberto e gravar após cada
troca; durante uma interrupção, a fala já capturada deve ser preservada.

### Microfone + áudio do computador

```bash
ZSPEAK_SKIP_SLOW=1 swift test --no-parallel --filter 'AudioTimelineMixerTests|RecordingAudioCaptureTests|SystemAudioSampleDecoderTests|AudioCaptureDeviceChangeTests|RecordingControllerTests'
```

Cobertura: fontes simultâneas alinhadas por timestamp; pausas; buffers tardios;
PCM estéreo convertido para mono 16 kHz; cauda preservada no stop; retorno ao
modo microfone; cancelamento; falta de permissão sem fallback silencioso; e
nenhuma captura do computador durante o pré-aquecimento/idle.

Teste nativo opcional, em uma sessão macOS cujo **processo de teste** tenha
permissão de captura (é independente da permissão concedida ao app instalado):

```bash
ZSPEAK_TEST_SYSTEM_AUDIO=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel --filter SystemAudioCaptureIntegrationTests
```

Reproduz `Fixtures/pt-short.wav` por `afplay` e exige áudio real não silencioso
no ScreenCaptureKit. Sem permissão, falha explicitamente sem abrir prompts.

| Validação | Pré-condição | Ação | Resultado esperado / regra protegida |
|---|---|---|---|
| Interface | Modo combinado ligado em preferências isoladas | Renderizar Microfone e Permissões | Duas fontes identificadas e autorização pendente visível; snapshots automatizados |
| Captura nativa | Sessão autorizada e fixture local | Reproduzir WAV durante captura | Pelo menos 1 s de samples com sinal; integração automatizada |
| Uso real | App autorizado, fones e vídeo/reunião | Gravar áudio do computador e falar, depois parar | Histórico contém as duas fontes; complementa testes de mistura e retorno ao microfone |

### Somente áudio do computador / AirPods — 1.0.66

`Capturar áudio do computador` ligado e `Incluir meu microfone` desligado
não abre nem pré-aquece o microfone, não exige sua permissão e não tenta outro
microfone como fallback. Os testes de `RecordingAudioCaptureTests` e
`RecordingControllerTests` cobrem essas regras, prontidão antes de dar play,
interrupção do stream, ganho integral, cauda, fontes congeladas e retorno ao
modo microfone. `AudioTimelineMixerTests` cobre reprodução após silêncio longo.

```bash
CI=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel --filter 'RecordingAudioCaptureTests|RecordingControllerTests|AudioTimelineMixerTests|AudioCaptureDeviceChangeTests|SystemAudioSampleDecoderTests|MicrophoneManagerTests|LiveTranscriptionTests|AppStateTests'
ZSPEAK_TEST_SYSTEM_AUDIO=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel --filter 'SystemAudioCaptureIntegrationTests/systemOnlyPreservesAudioRoute'
```

O teste nativo reproduz uma fixture por outro processo, verifica os dispositivos
de entrada e saída 16 vezes durante a captura e ao terminar, e exige transcrição
reconhecível pelo Parakeet real. Não troca dispositivos. Para comprovar AirPods,
eles precisam estar conectados e selecionados como saída antes da execução.

| Validação | Pré-condição | Ação | Resultado esperado / regra protegida |
|---|---|---|---|
| Interface | Preferências isoladas, captura do computador ligada | Renderizar Microfone e Permissões; inspecionar imagem | Opção de microfone desligada e fonte única explícita; snapshots automatizados |
| Reprodução real | Processo de teste autorizado e fixture WAV | Executar `systemOnlyPreservesAudioRoute` | Texto reconhecido e entrada/saída inalteradas; integração automatizada |
| App instalado | Bundle 1.0.66, app ocioso | Abrir Microfone e ativar só computador | Opções corretas na interface; regras cobertas pelos testes de captura/controller |

Validação desta correção: 92 testes de regressão, 5 snapshots e 1 integração
nativa passaram. O bundle 1.0.66 (166) foi instalado e conferido pela interface,
com captura do computador ligada e microfone adicional desligado. A integração
usou a saída interna do Mac; não havia AirPods
na enumeração de áudio naquele momento. O reteste físico com eles é complementar.

### Atalho de troca de fonte durante a gravação — 1.0.67

`⌃⌥A` alterna exclusivamente computador/microfone, mantendo o timer, o destino,
o preview e os trechos já capturados. As preferências só mudam após a troca
bem-sucedida. Uma falha tenta retomar a fonte anterior; stop/cancel espera a
limpeza da troca. Não há duas trocas simultâneas.

```bash
CI=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel --filter 'RecordingAudioCaptureTests|RecordingControllerTests|RecordingSourceShortcutTests|TrayInfoOverlayTests'
ZSPEAK_TEST_SYSTEM_AUDIO=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel --filter 'SystemAudioCaptureIntegrationTests/switchingSourcesPreservesRealPlayback'
```

| Validação | Pré-condição | Ação | Resultado esperado / regra protegida |
|---|---|---|---|
| Atalho instalado | App 1.0.67 ocioso, fonte computador | Pressionar ⌃⌥A duas vezes | Alterna microfone/computador sem gravar; controller e shortcut testados |
| Sessão contínua | Gravação ativa | Alternar fontes e parar durante troca | Trechos e timer preservados, um só resultado; testes de captura/controller |
| Hardware | Permissões de captura e microfone | Reproduzir fixture, trocar para mic e voltar, reproduzir de novo | ASR reconhece as duas falas; integração nativa |
| Interface | Preferências isoladas e modelos de UI | Renderizar atalhos e três fontes do indicador | Atalho visível e fonte legível; snapshots automatizados |

Validação da 1.0.67: 106 testes de regressão e 5 cenários visuais passaram,
além de uma integração nativa que reconheceu as duas reproduções após alternar
as fontes. Bundle assinado instalado com cópia da 1.0.66 preservada. A interface
mostrou `⌃⌥A` registrado. A tecla sintetizada pelo Computer Use não acionou o
atalho global; o acionamento por teclado físico precisa de confirmação do usuário.

### Inicialização após troca — 1.0.68

A revisão para publicação da 1.0.68 acrescenta a mesma tolerância de 2 segundos
do início da gravação ao monitoramento após trocar a fonte. A regressão em
`RecordingControllerTests` cobre microfone Bluetooth que começa a enviar áudio
após 500 ms e encerramento com preservação do texto quando ele não responde.

Antes desse ajuste final, a suíte de CI local passou com 607 testes. Depois,
os 14 testes do controller (incluindo os dois casos novos) passaram. Uma
repetição ampla ficou bloqueada no HAL/CoreAudio, com engines reais abertos
pelos testes de AppState; o processo de teste foi encerrado. Os dois benchmarks
sem hardware também passaram. O acionamento por teclado físico segue pendente.

### Desempenho da captura

```bash
./scripts/perf_capture_bench.sh --seconds 600 --trials 5 --check > /tmp/zspeak-capture-performance.json
./scripts/perf_capture_bench.sh --seconds 3600 --trials 3 --check > /tmp/zspeak-capture-hour.json
```

Compila os arquivos reais com `-O`; simula áudio em velocidade máxima, sem
microfone, ASR ou espera de uma hora. Mede conversão estéreo 48 kHz, mistura de
duas fontes e emissão de buffers grandes. Valida número/ordem dos samples e
reporta p50/p95, maior callback observado, stop e pico de memória do processo.
O pico é cumulativo entre cenários/rodadas; não representa a RAM do app completo.

O CI executa 60 s simulados com margem de p95 < 1 ms por bloco de 10 ms e
tempo total de mistura < 1% da duração simulada. Testes funcionais complementam
esse gate: tamanhos variáveis e reconexão no resampler, produtores concorrentes
e limites de páginas no mixer, emissão grande sem perda/duplicação no emitter.

| Validação | Pré-condição | Ação | Resultado esperado / regra protegida |
|---|---|---|---|
| Benchmark otimizado | Apple Silicon, toolchain Swift, fontes atuais | Executar 10 min e 1 h simulados, antes/depois | Preservar samples e manter folga para tempo real; assertions no runner e gate do CI |
| Latência nativa | Microfone/captura autorizados, fixture local | Iniciar captura combinada, reproduzir WAV, parar e transcrever | Primeiro sample antes de 2 s e fixture reconhecida; `SystemAudioCaptureIntegrationTests` registra início/stop/ASR |

### Acurácia e velocidade — 1.0.69

```bash
CI=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel --filter 'AudioFileTranscriberTests|FileTranscriptionQueueTests|LiveTranscriptionTests|VocabularyStoreTests|VocabularyReplacementsTests|PTBRTextNormalizer'
./scripts/perf_audio_sanitization.sh
./scripts/perf_vocabulary.sh
./scripts/perf_live_preview_backlog.sh
```

Regressões: vocabulário sem cascatas, Unicode e identificadores preservados;
zeros/precisão decimal; leitura de arquivos fora da UI; cancelamento inclusive
com erro de I/O tardio; temporários preservados até terminar o leitor;
preview limitado por inferência com samples em ordem e fechamento sem backlog.

| Validação | Entrada / pré-condição | Ação | Resultado esperado / automação |
|---|---|---|---|
| Pós-processamento | Corpus determinístico e revisão `4daadce` disponível | Executar benchmark e testes do vocabulário/ITN | Defeitos anteriores reproduzidos; saídas corretas; texto comum idêntico |
| PCM | Buffers válidos, inválidos e bits arbitrários | Sanitizar pela referência e implementação | Float32 bit a bit idêntico; benchmark mede reutilização do buffer |
| UI e cancelamento | Leitor bloqueado injetado | Cancelar a leitura, limpar/resetar a fila | MainActor livre, ASR não executado e arquivos preservados até leitor encerrar |
| Preview atrasado | 40 s de áudio com silêncio apenas no fim | Processar backlog, parar/cancelar | Inferência de até 12 s + padding; sinal integral em ordem; nenhum trabalho novo após fechar |

Os benchmarks medem etapas isoladas, não o ASR completo. O A/B real permanece
em `SpeechQualityPerformanceTests`; resultados e limites estão em
[`docs/performance-speech-quality.md`](../docs/performance-speech-quality.md).

### Otimização sem perda de qualidade

```bash
CI=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel --filter 'AudioSamplePaddingTests|LiveTranscriptionTests|RecordingControllerTests|AudioFileTranscriberTests'
./scripts/perf_speech_preparation.sh > /tmp/speech-preparation.json
ZSPEAK_TEST_ASR_QUALITY=1 ZSPEAK_SKIP_SLOW=1 ZSPEAK_QUALITY_REPORT_PATH=/tmp/asr-quality.json swift test --no-parallel --filter SpeechQualityPerformanceTests
```

A referência congelada da 1.0.64 em `Support/SpeechPreparationReference.swift`
protege os bits do sinal, margens da fala e ganho. Não deve acompanhar mudanças
de implementação. O benchmark Release alterna referência/candidato e mede
o preenchimento das bordas e o pipeline RMS; exige samples idênticos.
O CI roda esse gate sem modelos. O A/B opcional usa o Parakeet real, Silero VAD
e seis casos: PT-BR, termos técnicos, fala baixa, rumble, bordas silenciosas e
silêncio. Exige o mesmo texto e nenhuma piora de WER/CER em três repetições.

| Validação | Pré-condição | Ação | Resultado esperado / regra protegida |
|---|---|---|---|
| Waveform e tempo | Fontes atuais e referência 1.0.64 | Executar benchmark Release de 1 a 600 s | Samples idênticos bit a bit; sem reduzir fidelidade para economizar cópias |
| Qualidade real | Fixtures locais e modelos Parakeet/Silero disponíveis | Transcrever referência/candidato alternadamente | Mesmo texto, WER e CER; `SpeechQualityPerformanceTests` |
| Stop | Preview ocupado e áudio pendente no pipe | Parar/cancelar gravação | Preview fechado antes da drenagem e batch completo preservado; regressões em `LiveTranscriptionTests` e `RecordingControllerTests` |

---

## Fixtures de áudio

As fixtures ficam em `Tests/Fixtures/` e são commitadas no repo.

### Regenerar fixtures

```bash
bash Tests/Fixtures/generate.sh
```

Usa `say` (nativo macOS, voz `Luciana` PT-BR) e gera:

- `pt-short.wav` — "Olá mundo, teste de transcrição local." (~2.8s)
- `pt-long.wav` — parágrafo com code-switching (deploy/Kubernetes/PostgreSQL/Redis, ~13s)
- `silence.wav` — 5s de silêncio (via `afconvert`)

Todos em WAV PCM 16-bit mono 16kHz (formato nativo do pipeline Parakeet).

### Adicionar nova fixture

1. Edite `Tests/Fixtures/generate.sh`.
2. Rode o script.
3. Adicione um `@Test` em `TranscriberIntegrationTests.swift`.
4. Commite o WAV junto do teste.

---

## Snapshots visuais

`VisualSnapshotTests` compara renderização de views SwiftUI com PNGs em `Tests/__Snapshots__/`.

### Gravar / atualizar snapshots

```bash
ZSPEAK_RECORD_SNAPSHOTS=1 swift test --filter "VisualSnapshot"
```

Isso sobrescreve os PNGs de referência. Revise o `git diff` antes de commitar.

Quando rodar via `xcodebuild` e a variável não for repassada para o processo de
teste, use o sentinela local:

```bash
touch Tests/.record-snapshots
xcodebuild test -scheme zspeak -destination 'platform=macOS' -only-testing:zspeakTests/VisualSnapshotTests
rm Tests/.record-snapshots
```

### Rodar comparando (modo padrão)

```bash
swift test --filter "VisualSnapshot"
```

Falha se o pixel diff ultrapassar a tolerância configurada.

---

## Variáveis de ambiente reconhecidas

| Variável                   | Efeito                                                         |
| -------------------------- | -------------------------------------------------------------- |
| `ZSPEAK_SKIP_SLOW=1`       | Pula `TranscriberIntegrationTests` (download de modelo).       |
| `ZSPEAK_RECORD_SNAPSHOTS=1`| Regrava os PNGs de referência em vez de comparar.              |
| `CI=1` (auto no GH Actions)| Pula testes que dependem de microfone real.                    |

---

## Xcode vs CLI

### CLI (`swift test`)

- Mais rápido para iterar.
- Respeita env vars normalmente.
- Exemplo: `ZSPEAK_SKIP_SLOW=1 swift test`.

### Xcode

- Abra `Package.swift` no Xcode e use `Cmd+U`.
- Para setar env vars: `Product → Scheme → Edit Scheme... → Test → Arguments → Environment Variables`.
- Adicione `ZSPEAK_SKIP_SLOW = 1` para pular integração.
- Filtre suites via Test Navigator (Cmd+6), checkbox por teste.

---

## CI

O workflow `.github/workflows/ci.yml` roda por padrão com
`ZSPEAK_SKIP_SLOW=1`. Suites de integração lenta, hardware, snapshots e timing
visual continuam disponíveis localmente, mas se auto-desativam no runner CI para
evitar downloads grandes e medições falsas causadas pelo ambiente compartilhado.
