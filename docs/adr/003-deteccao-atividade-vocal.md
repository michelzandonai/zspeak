# ADR 003: Deteccao de Atividade Vocal — Silero VAD via FluidAudio

## Status

**Superseded — 2026-04-16** (ver secao "Revisao 2026-04-16" abaixo).

Originalmente: Aceito.

## Contexto

O app precisa detectar quando o usuario esta falando vs em silencio para:

- Evitar enviar silencio para o modelo de transcricao (causa alucinacoes em modelos como Whisper)
- Saber quando a fala terminou para processar o buffer
- Reduzir computacao desnecessaria

Opcoes avaliadas:

| Opcao | Descricao |
|---|---|
| **Silero VAD** (via FluidAudio, CoreML) | ~2 MB, 32ms chunks, sub-millisecond latency |
| **Silero VAD** (via ONNX Runtime) | Mesma qualidade, mas requer ONNX Runtime separado |
| **WebRTC VAD** (libfvad) | GMM-based, mais leve mas menos preciso |
| **Threshold simples** (amplitude) | Mais simples mas falha com ruido de fundo |

## Decisao

Adotamos **Silero VAD v5 via FluidAudio** (CoreML).

## Justificativa

### Qualidade

- Melhor VAD open source disponivel (2024-2026)
- v5: speech starts se 50% dos frames dentro de 10 frames (0.32s) excedem 70% de probabilidade
- Muito baixo false positive rate (nao confunde ruido de fundo com fala)
- Funciona bem com microfones de qualidade variada

### Integracao nativa

- Ja vem incluso no FluidAudio — zero dependencia adicional
- Roda em CoreML/Apple Neural Engine — nao consome CPU
- Modelo CoreML pre-convertido: `FluidInference/silero-vad-coreml` (19k downloads no HuggingFace)

### Performance

- Processa chunks de 32ms (512 samples a 16kHz) em sub-millisecond
- Modelo de ~2-5 MB
- Overhead praticamente zero

### Configuracao

- Threshold de probabilidade de fala ajustavel
- Duracao minima de fala configuravel
- Duracao de silencio para "fim de fala" configuravel (padrao: 500ms)
- Padding de audio antes/depois da fala

## Consequencias

### Positivas

- Zero alucinacao — silencio nunca chega ao Parakeet TDT
- Economia de processamento — ASR so roda quando ha fala real
- Resposta rapida — detecta inicio de fala em ~320ms
- Mesma implementacao do Spokenly

### Negativas

- Latencia de ~320ms para detectar inicio de fala (aceitavel)
- Pode cortar fala muito curta (< 300ms) — configuravel via threshold

## Alternativas rejeitadas

- **WebRTC VAD**: Mais leve mas significativamente menos preciso, mais falsos positivos
- **Threshold de amplitude**: Falha com ruido de fundo, ar condicionado, ventilador
- **Silero VAD via ONNX**: Mesma qualidade mas requer runtime adicional (FluidAudio ja tem)

---

## Revisao 2026-04-16 — VAD removido

Esta ADR esta **superseded**. O `VADManager` foi removido do app (commit `afb4c6d`) e
nao ha mais detecao de atividade vocal no pipeline.

### Motivos da remocao

- A versao atual do FluidAudio (v0.12.6) **nao expoe mais o Silero VAD** pela API publica
  do `AsrManager`. O modelo CoreML continua no pacote, mas os wrappers que este ADR
  assumia (classe `VadManager` / configuracao por threshold/min-speech/min-silence)
  foram descontinuados.
- O fluxo real hoje e **push-to-talk**: o usuario controla inicio e fim da gravacao
  explicitamente via hotkey global (ver ADR 007). A janela de silencio entre
  pressionar/soltar a hotkey e o frame de audio e curta o suficiente para que
  alucinacoes do Parakeet TDT por "silencio" nao sejam um problema observado em uso real.
- Parakeet TDT v3 lida bem com silencio de bordas — o risco de alucinacao que motivou
  o VAD originalmente e caracteristico de Whisper, nao do modelo atual.
- Remover o VAD simplificou drasticamente o pipeline (menos estado, menos codigo,
  menos latencia de ~320ms na deteccao).

### Estado atual do pipeline

```
Mic → AVAudioEngine (captura continua enquanto hotkey ativa) → Parakeet TDT → Clipboard
```

Sem VAD, sem deteccao de fim-de-fala automatica. Fim de gravacao = usuario solta/pressiona
a hotkey.

### Se o VAD precisar voltar

- Reavaliar quando/se FluidAudio reexpor o Silero VAD na API publica
- Alternativa: integrar Silero VAD diretamente via CoreML (arquivo `.mlmodelc`),
  sem depender do wrapper do FluidAudio
- Reabrir esta ADR ou criar uma sucessora (ADR 003-revisao-YYYY)
