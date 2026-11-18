# ADR 001 · Modelo de transcrição

## Status

Aceito. O macOS usa o Parakeet Ultra a partir da versão 1.0.70. O Windows usa o Parakeet TDT 0.6B v3.

## Decisão de 18/11/2026 para o macOS

O Parakeet Ultra roda com a FluidAudio 0.18.3 e Core ML, em um cache próprio do zspeak. O vocabulário acústico usa bônus zero, similaridade mínima de 0,70 e pré-checagem de candidatos. O resgate puramente acústico fica desligado para preservar palavras comuns em dicionários pequenos. A prévia usa o decodificador sem reforço acústico e passa pelos aliases do app. A transcrição final usa o contexto de vocabulário do destino. Arquivos usam o vocabulário completo.

Na versão 1.0.71, os comandos Git de fábrica e `pull request` usam o perfil de desenvolvimento, que inclui o Codex. A atualização migra as entradas padrão intactas e preserva as personalizadas. A normalização e os aliases preservam URLs, caminhos e outros literais técnicos. Números agrupados são reformatados quando uma indicação explícita de porta e o intervalo válido confirmam o contexto.

O benchmark local avaliou 112 áudios, dos quais 69 eram gravações humanas. Com a configuração escolhida, o Ultra acertou 46 de 72 ocorrências técnicas em áudio sintético, ante 34 do v3 atual. A amostra teve zero inserções indevidas dos termos escolhidos. A pré-checagem preservou todas as saídas medidas e reduziu a mediana de inferência do Ultra com vocabulário de 63,3 para 50,8 ms. A prévia alcançou p95 de 1,06 s em replay de sete áudios, com duas repetições. A latência de colagem e a precisão em ditados técnicos espontâneos dependem de validação no uso diário.

Com o Ultra e 147 gravações locais, o benchmark de preparo mediu erro médio por palavra de 10,58% com trim por RMS, 10,16% com Silero e 9,90% com Silero e condicionamento de sinal. O tempo médio do último perfil foi de 113 ms, incluindo preparo e inferência. A comparação usa as referências salvas na aba Benchmark e sustenta manter o preparo atual.

O retorno à versão anterior usa o bundle assinado 1.0.69. Histórico, preferências e pesos ficam fora do bundle. [Modelo Core ML](https://huggingface.co/FluidInference/parakeet-ultra-coreml) · [Perfil de vocabulário na FluidAudio](https://github.com/FluidInference/FluidAudio/blob/v0.18.3/Documentation/ASR/CustomVocabulary.md)

## Decisão original

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
