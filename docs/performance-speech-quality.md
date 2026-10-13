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
