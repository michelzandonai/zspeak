# Acurácia, desempenho e velocidade — 1.0.69

Três frentes independentes e revisão cruzada, sobre `4daadce` (1.0.68).
Medições locais no Apple M5 Pro, macOS 26.6.2, Xcode 27.0, em 17/10/2026.

## Comportamento corrigido

- **Texto:** substituições de vocabulário em uma passagem, sem reaplicar aliases
  ao texto recém-inserido. Preserva identificadores como `posh_name`, marcas
  combinantes, acentos compostos/decompostos e símbolos literais. Na mesma
  posição vence o alias mais longo; entre posições sobrepostas vence a primeira.
- **Números:** `três vírgula 05` vira `3,05`; `zero vírgula cinco por cento`
  vira `0,5%`; `paguei vinte uma vez` mantém o artigo em `paguei 20 uma vez`.
  Zeros à esquerda e precisão dos dígitos escritos são preservados.
- **Arquivos:** leitura/resampling/sanitização saem da thread da interface.
  PCM já válido reutiliza seu buffer; samples inválidos mantêm a sanitização
  anterior. Cancelar espera o leitor síncrono terminar, impede o ASR e adia a
  remoção de arquivos temporários, inclusive ao limpar a fila.
- **Preview:** o corte considera no máximo os primeiros 12 s do áudio pendente.
  Um backlog de 40 s não vira uma inferência única de quase 40 s. Os commits
  permanecem seriais e conservam os samples em ordem. Stop/cancel aguarda a
  inferência ativa e não processa o backlog restante.

Modelo Parakeet, Neural Engine, sinal Float32, filtros, Silero VAD, margens e
parâmetros do decoder permanecem iguais. O batch final continua recebendo todo
o áudio capturado. A cobertura de fidelidade compara bytes, texto, WER e CER.

## Resultados desta revisão

- **628 testes** na suíte rápida e **6 testes de integração/benchmark com o
  Parakeet real** passaram. O A/B protege seis condições de áudio; texto,
  WER/CER e Float32 permaneceram iguais à referência.
- O corpus reproduz e corrige **10 defeitos de pós-processamento**. A revisão
  independente comparou 9.019 pares Unicode e 70 conflitos entre aliases,
  sem perdas involuntárias após os ajustes.
- Preview real em `pt-long.wav`: 17 atualizações, primeira em 0,91 s. Isso é
  uma medição funcional local, sem alegação de aceleração geral do ASR.

| Etapa isolada | Antes | Depois | Escopo |
|---|---:|---:|---|
| Sanitizar PCM válido, 10 min | 21,888 ms | 4,684 ms | −78,6%; evita cópia de 38,4 MB |
| Sanitizar PCM válido, 1 h | 127,835 ms | 25,271 ms | −80,2%; evita cópia de 230,4 MB |
| Vocabulário, frase técnica, 128 aliases, cache | 0,151 ms | 0,017 ms | 9,1×; texto idêntico |
| Vocabulário acentuado, texto ~2 KB, cache | 4,543 ms | 2,471 ms | 1,8×; texto idêntico |
| Busca de corte em backlog de 40 s, 60 buscas | 65,277 ms | 8,114 ms | CPU, sem inferência ASR |
| Maior chamada no backlog sintético | 39,36 s de áudio | 8,32 s de áudio | Inclui padding; sinal integral preservado |

Sanitização e vocabulário usam nove rodadas alternadas e medianas, com consumo
integral/comparação da saída. A busca de corte é um microbenchmark simples;
o gate relevante limita cada inferência a 12 s + 200 ms de padding. O conjunto
ASCII do vocabulário ficou entre 5,1× e 28,7× e o acentuado entre 1,8× e 2,6×.

## Como reproduzir

```bash
CI=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel
./scripts/perf_audio_sanitization.sh
./scripts/perf_vocabulary.sh
./scripts/perf_live_preview_backlog.sh
./scripts/perf_speech_preparation.sh
./scripts/perf_capture_bench.sh --seconds 60 --trials 5 --check
CI=1 ZSPEAK_TEST_ASR_QUALITY=1 ZSPEAK_RUN_LIVE_BENCHMARK=1 \
  swift test --no-parallel --filter 'SpeechQualityPerformanceTests|TranscriberIntegrationTests|LiveTranscriptionBenchmarkTests'
```

O benchmark de vocabulário lê o normalizador anterior pela revisão fixa
`4daadce01a08c24a884a7d53d6daea539f030617`; essa revisão precisa existir no clone.
O CI busca o histórico e executa os três novos benchmarks sem modelos/hardware.
Os gates exigem fidelidade e limite de inferência; os tempos são evidência,
sem limiar frágil dependente da máquina.

## Limites da evidência

Ganhos de sanitização e substituição pertencem a essas etapas, não ao tempo
inteiro de transcrição. O corpus de defeitos é pequeno e determinístico; não
mede melhora geral do reconhecimento da voz. O A/B com modelo real usa fixtures
PT-BR/termos técnicos e suas variações, sem gravações pessoais.

O limite de preview vale por inferência, não para a memória de um backlog
arbitrariamente longo. A política anterior para caudas abaixo de 1 s permanece;
o texto final usa o áudio completo. Cancelamento de leitura é cooperativo: a
UI responde, mas o conversor síncrono precisa terminar antes da limpeza.

Evidências da revisão atual e hashes das fontes:
[quality-speed-1.0.69.json](performance/quality-speed-1.0.69.json).

---

# Otimização com qualidade preservada — 1.0.65

Comparação com a 1.0.64 no Apple M5 Pro, macOS 26.6.2, em 12/10/2026.

## Mudanças mantidas

- Preenchimento das bordas silenciosas em uma alocação e uma cópia da fala.
  Mesmos 250 ms de margem no batch e 200 ms no preview; mesmo mínimo de 1 s.
- Snapshot independente do preview: a janela de gravação pode crescer sem
  copiar novamente o buffer que a inferência está usando.
- Commit copia diretamente o range da fala para o buffer preparado.
- Stop/cancel fecha o preview antes de drenar o pipe, evita novas inferências
  da cauda e aguarda o cancelamento da prediction já ativa. O batch recebe
  todo o áudio final. Buffers do preview são liberados ao fechar.

O modelo Parakeet, precisão Float32, Neural Engine, filtros, Silero VAD,
normalização, corte da fala e parâmetros do decoder permanecem iguais.
A alternativa de otimizar o filtro/RMS não apresentou ganho consistente e foi
descartada antes da entrega.

## Desempenho medido

Benchmark Release com sete rodadas alternadas, consumidores lendo os samples
e comparando seus bits com uma referência congelada da versão anterior:

| Etapa de padding de segmento | Referência | 1.0.65 | Menos tempo |
|---|---:|---:|---:|
| 1 s de áudio | 0,0055 ms | 0,0020 ms | 62,6% |
| 8 s de áudio | 0,0191 ms | 0,0095 ms | 50,5% |
| 60 s de áudio | 0,1356 ms | 0,0751 ms | 44,6% |
| 600 s de áudio | 1,5608 ms | 0,7460 ms | 52,2% |

Esse ganho pertence ao preparo das bordas, não ao tempo total do ASR. O pipeline
RMS completo permaneceu próximo ao anterior, e o custo da inferência varia
entre rodadas. Os dois pipelines entregam os mesmos bits ao modelo.

## Qualidade real

Parakeet + Silero VAD, três repetições alternadas por caso. Todos devolveram o
mesmo texto final nas duas versões. WER mede erros de palavras; CER, de caracteres.

| Caso | WER antes/depois | CER antes/depois | Samples idênticos |
|---|---:|---:|---|
| PT-BR curto | 0% / 0% | 0% / 0% | Sim |
| Termos técnicos em inglês | 6,45% / 6,45% | 1,70% / 1,70% | Sim |
| Fala baixa | 0% / 0% | 0% / 0% | Sim |
| Fala com ruído de baixa frequência | 0% / 0% | 0% / 0% | Sim |
| Bordas silenciosas | 16,67% / 16,67% | 8,33% / 8,33% | Sim |
| Silêncio | 0% / 0% | 0% / 0% | Sim; ASR dispensado |

Os erros já existentes nos termos técnicos/bordas são iguais nas duas versões.
Esse ensaio demonstra ausência de regressão nesses casos, não uma garantia de
acerto para qualquer gravação ou ruído. Usou fixtures locais e variações
determinísticas; não envia gravações para serviços externos.

## Gates

- 592 testes passaram; regressões protegem padding bit a bit, range do commit,
  áudio do preview, cancelamento de inferência e ordem do stop com batch completo.
- A/B com modelo real: `SpeechQualityPerformanceTests`, aprovado nos seis casos.
- Captura real e benchmark ao vivo verificados separadamente.
- O CI executa o benchmark de preparo e exige igualdade dos samples. O A/B
  com modelo real é opcional e explícito, pois requer modelos locais.

```bash
CI=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel
./scripts/perf_speech_preparation.sh > /tmp/speech-preparation.json
ZSPEAK_TEST_ASR_QUALITY=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel --filter SpeechQualityPerformanceTests
```

Medições, resultados A/B e hashes das fontes:
[speech-quality-1.0.65.json](performance/speech-quality-1.0.65.json).
