# ADR 001: Modelo de Transcricao — NVIDIA Parakeet TDT 0.6B V3

## Status

Aceito

## Contexto

O projeto zspeak precisa de um modelo de speech-to-text que:

- Rode 100% local no Apple Silicon (M1+)
- Suporte portugues brasileiro com termos tecnicos em ingles (code-switching)
- Tenha baixa alucinacao (nao gere texto quando ha silencio)
- Seja rapido o suficiente para uso em tempo real
- Tenha tamanho razoavel (< 1 GB)

Modelos avaliados:

| Modelo | Idiomas | Alucinacao em silencio | WER PT-BR | Tamanho |
|---|---|---|---|---|
| OpenAI Whisper (tiny a large-v3) | 99 | Sim | Maior | 39M–1.55B |
| Whisper large-v3-turbo | 99 | Sim | Maior | ~809M |
| NVIDIA Parakeet TDT 0.6B V3 | 25 europeus | Nao | 4.76% FLEURS | ~600M |

## Decisao

Adotamos o **NVIDIA Parakeet TDT 0.6B V3** como modelo unico de transcricao.

## Justificativa

### Performance

- WER PT-BR: 4.76% (FLEURS), 3.96% (CoVoST) — melhor que Whisper large-v3 para portugues
- WER Ingles: 6.34% (Open ASR Leaderboard) — melhor que Whisper large-v3 (7.4%)
- Velocidade: ~110x real-time no Apple Neural Engine via CoreML
- 600M parametros (vs 1.55B do Whisper large-v3) — mais leve e rapido

### Baixa alucinacao

- Arquitetura TDT (Token-and-Duration Transducer) modela duracao dos tokens explicitamente
- Silencio e tratado como "blank frames" — nao gera tokens espurios
- Testado em uso real no Spokenly: confirmado que nao alucina em silencio

### Code-switching PT-BR + EN

- Reconhece termos tecnicos em ingles nativamente (GitHub, git pull, deploy, branch, API)
- Nao precisa de pos-processamento com LLM para corrigir termos
- 25 idiomas europeus incluem portugues

### Tamanho

- ~496 MB (CoreML format)
- Auto-download do HuggingFace: `FluidInference/parakeet-tdt-0.6b-v3-coreml`

### Validacao

- Mesmo modelo usado em producao pelo Spokenly (100k+ usuarios ativos)
- Licenca CC-BY-4.0 (uso comercial permitido)

## Consequencias

### Positivas

- Melhor accuracy para PT-BR que qualquer Whisper
- Sem alucinacao em silencio
- Termos tecnicos reconhecidos sem pipeline adicional
- Modelo compacto, rapido no ANE

### Negativas

- 25 idiomas (vs 99+ do Whisper) — limitacao aceitavel para MVP
- Streaming ASR (EOU model) so suporta ingles por enquanto
- Dependencia do formato CoreML para performance maxima

### Riscos

- Se o modelo parar de ser mantido pela NVIDIA → mitigado: FluidAudio mantem forks CoreML
- Se precisar de idiomas fora dos 25 europeus → precisara de Whisper como fallback

## Alternativas rejeitadas

- **Whisper large-v3**: Mais idiomas, mas alucina em silencio, mais lento, pior WER para PT-BR
- **Whisper large-v3-turbo**: Mais rapido que large-v3, mas ainda alucina
- **Parakeet TDT 1.1B**: Melhor para ingles, mas nao suporta multilingue
- **Modelos cloud (Deepgram, Groq)**: Requisito e 100% local
