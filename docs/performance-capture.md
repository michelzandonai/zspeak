# Desempenho da captura — 1.0.64

Medição em 12/10/2026, Apple M5 Pro, 18 núcleos, 64 GB, macOS 26.6.2.
As otimizações reduzem alocações na conversão e evitam copiar toda a gravação
dentro do callback das duas fontes. O sinal continua mono float32 a 16 kHz;
o conversor mantém sua qualidade máxima e estado entre callbacks.

## Comparação antes/depois

Benchmark compila os arquivos reais com `swiftc -O -whole-module-optimization`.
Alimenta áudio em velocidade máxima: dez minutos/uma hora são durações
**simuladas**, sem espera, ASR, interface ou captura de hardware.
Tempos abaixo são medianas de cinco rodadas para 10 min e três para 1 h.
Os consumidores leem todos os samples e verificam o sinal, evitando que o
otimizador elimine trabalho que existe na captura entregue ao transcritor.

| Trabalho | Áudio simulado | Antes | Depois | Redução |
|---|---:|---:|---:|---:|
| Conversão estéreo 48 kHz → mono 16 kHz | 10 min | 151,52 ms | 119,77 ms | 21,0% |
| Mistura de microfone + computador e emissão ao vivo | 10 min | 44,77 ms | 33,77 ms | 24,6% |
| Emissão de um buffer grande ao transcritor | 30 s | 2,61 ms | 0,48 ms | 81,7% |
| Conversão estéreo 48 kHz → mono 16 kHz | 1 h | 929,37 ms | 715,08 ms | 23,1% |
| Mistura de microfone + computador e emissão ao vivo | 1 h | 291,93 ms | 191,04 ms | 34,6% |

Na simulação de 1 h, o maior callback observado da mistura caiu de 21,47 ms
para 0,110 ms; p95 caiu de 1,500 µs para 0,542 µs. A coleta inclui possíveis
preempções do sistema, portanto o máximo não é garantia de latência futura.
A gravação agora usa páginas fixas de um segundo; o array contíguo é montado
no stop, fora do callback. Essa montagem levou no máximo 22,18 ms na simulação
de 1 h, em vez de transferir esse custo para a captura.

O pico RSS **cumulativo do processo de benchmark** passou de 655,9 MB para
518,7 MB no ensaio de 1 h. Em 10 min passou de 110,4 MB para 98,6 MB:
o allocator e a montagem final também influenciam esse valor. A gravação retém
o áudio completo (64 KB/s, cerca de 230 MB/h), necessário para o resultado final.
Esses números não representam a memória total do app ou do modelo ASR.

## Captura real e regressões

ScreenCaptureKit + microfone real + reprodução de `Tests/Fixtures/pt-short.wav`:
primeiro sample do microfone em **854,72 ms**; stop em **73,28 ms**;
**4,82 s de áudio transcritos em 149,22 ms**, com o Parakeet já carregado.
A fixture foi reconhecida. O tempo ASR não inclui carregamento inicial do modelo.

- 585 testes passaram na suíte padrão; cinco novas regressões cobrem tamanhos
  variáveis/reset do conversor, emissão grande em ordem, páginas e concorrência.
- Dois testes nativos de captura/transcrição passaram.
- O benchmark ao vivo preservou os parciais crescentes e o texto final.
- O CI passa a executar um ensaio sem hardware de 60 s simulados: p95 < 1 ms
  para blocos de 10 ms e tempo de mistura < 1% da duração simulada. Essa margem
  detecta regressões relevantes sem exigir o desempenho específico deste M5.

Reproduzir:

```bash
CI=1 ZSPEAK_SKIP_SLOW=1 swift test --no-parallel
./scripts/perf_capture_bench.sh --seconds 600 --trials 5 --check > /tmp/capture-600.json
./scripts/perf_capture_bench.sh --seconds 3600 --trials 3 --check > /tmp/capture-3600.json
ZSPEAK_TEST_SYSTEM_AUDIO=1 ZSPEAK_SKIP_SLOW=1 swift test --skip-build --no-parallel --filter SystemAudioCaptureIntegrationTests
ZSPEAK_RUN_LIVE_BENCHMARK=1 ZSPEAK_SKIP_SLOW=1 swift test --skip-build --no-parallel --filter LiveTranscriptionBenchmarkTests
```

Os testes nativos exigem permissões previamente concedidas ao processo de teste.
Não houve alteração nas permissões, seleção de microfone ou qualidade do ASR.
O ensaio foi executado neste Mac; ainda não há medição equivalente em M1/M2.
Resultados brutos e hashes das fontes: [capture-1.0.64.json](performance/capture-1.0.64.json).
