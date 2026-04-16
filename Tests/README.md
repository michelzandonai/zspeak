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
ZSPEAK_SKIP_SLOW=1 swift test
```

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

O workflow `.github/workflows/ci.yml` (configurado em paralelo por outro agente) roda
por padrão com `ZSPEAK_SKIP_SLOW=1`. O suite de integração só executa manualmente
(via `workflow_dispatch`) para evitar baixar 496 MB em todo push.
