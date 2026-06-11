---
type: migration-plan
project: zspeak
status: proposed
date: 2026-05-07
owner: Michel Zandonai
tags:
  - zspeak/docs
  - zspeak/obsidian
  - docs/migration
---

# Plano de Migração para Obsidian

## Resumo

O projeto já está perto de um vault Obsidian: a documentação principal está em Markdown, as ADRs têm numeração clara e as tarefas têm metadados estruturados em JSON. A migração deve focar menos em "converter formato" e mais em transformar os documentos em uma base navegável, com propriedades consistentes, links entre produto, arquitetura, backlog e código, além de dashboards via Bases.

Recomendação: usar a raiz do repositório como vault Obsidian para permitir links para código, testes e scripts, mas manter a documentação em `docs/` e excluir ruído como `.build/`, `.git/`, snapshots e fixtures de áudio.

## Inventário Local

| Área | Arquivos | Estado |
|---|---:|---|
| README / instruções de agentes | `README.md`, `AGENTS.md`, `CLAUDE.md` | úteis, mas duplicam informações e precisam ser consolidados em uma nota canônica |
| Produto | `docs/prd/mvp.md` | bom material de PRD, mas mistura MVP original com pós-MVP já implementado |
| ADRs | `docs/adr/001` a `010` | boa base; precisa normalizar status/frontmatter e linkar decisões relacionadas |
| Boas práticas | `docs/best-practices/accessibility-api.md` | muito útil, mas longo; deve virar referência técnica com propriedades |
| Backlog | `docs/tasks/TASK-001` a `TASK-013` em JSON | rico em contexto, mas Obsidian Bases funciona melhor com Markdown + YAML frontmatter |
| Testes | `Tests/README.md` | deve entrar como guia operacional de QA |
| Código | `zspeak/*.swift`, `Tests/*.swift`, `scripts/*.sh` | deve ser referenciado por notas, não migrado para docs |

## Achados Importantes

1. O pipeline atual é push-to-talk controlado por hotkey, sem VAD. O histórico da decisão permanece no ADR 003, marcado como superseded.
2. `AGENTS.md` e `CLAUDE.md` estão praticamente duplicados. No Obsidian, isso deve virar uma única nota canônica de regras do projeto, com links para versões específicas quando necessário.
3. `TASK-002`, `TASK-003` e `TASK-004` seguem `in_progress`, mas há implementação correspondente no código (`AudioFileTranscriber`, `DiarizationManager`, `FFmpegTranscoder`) e testes. Esses status precisam de triagem antes da migração.
4. O projeto evoluiu além do MVP original: há transcrição de arquivo, diarização, prompt mode com LLM local, vocabulário customizado, histórico, snapshots visuais e CI.

## Padrão Obsidian Recomendado

### Estrutura

```text
docs/
├── _index.md
├── _bases/
│   ├── adr.base
│   ├── backlog.base
│   └── docs-health.base
├── _templates/
│   ├── adr.md
│   ├── task.md
│   ├── runbook.md
│   └── research.md
├── 00-produto/
│   ├── PRD - MVP.md
│   └── Roadmap.md
├── 10-arquitetura/
│   ├── MOC - Arquitetura.md
│   └── ADR-001 - Modelo de Transcricao.md
├── 20-engenharia/
│   ├── Pipeline de Audio.md
│   ├── Transcricao de Arquivos.md
│   ├── LLM Local.md
│   └── Testes e CI.md
├── 30-operacao/
│   ├── Build Local.md
│   ├── Packaging e Notarizacao.md
│   └── Permissoes macOS.md
├── 40-backlog/
│   └── TASK-001 - Fix Transcriber.md
└── 90-referencias/
    ├── Accessibility API macOS.md
    └── Pesquisa - Obsidian.md
```

### Propriedades

Use propriedades pequenas e atômicas. Evite Markdown dentro de properties e evite objetos aninhados.

Campos base:

```yaml
---
type: adr
status: accepted
date: 2026-04-16
updated: 2026-05-07
owner: Michel Zandonai
area:
  - audio
  - asr
tags:
  - zspeak/architecture
  - zspeak/audio
related:
  - "[[ADR-002 - Runtime de Inferencia]]"
code_paths:
  - zspeak/Transcriber.swift
  - zspeak/RecordingController.swift
---
```

Tipos sugeridos:

| `type` | Uso |
|---|---|
| `index` | MOCs e páginas de navegação |
| `prd` | requisitos e visão de produto |
| `adr` | decisões arquiteturais |
| `task` | backlog convertido dos JSONs |
| `runbook` | build, testes, release, permissões |
| `reference` | material técnico estável |
| `research` | pesquisa externa com fontes e data |

Statuses sugeridos:

| Tipo | Status |
|---|---|
| ADR | `proposed`, `accepted`, `revised`, `superseded`, `rejected` |
| Task | `todo`, `in-progress`, `blocked`, `completed`, `cancelled` |
| Documento | `draft`, `active`, `stale`, `archived` |

### Tags

Use tags para tema, não para substituir campos estruturados:

```yaml
tags:
  - zspeak/asr
  - zspeak/audio
  - zspeak/macos
  - docs/adr
```

Tags aninhadas ajudam nos filtros: `zspeak/audio`, `zspeak/llm`, `zspeak/packaging`, `docs/runbook`.

## Bases

Backlog:

```yaml
filters:
  and:
    - 'type == "task"'
properties:
  status:
    displayName: Status
  area:
    displayName: Area
  owner:
    displayName: Owner
views:
  - type: table
    name: "Ativas"
    filters:
      and:
        - 'status != "completed"'
        - 'status != "cancelled"'
    order:
      - file.name
      - status
      - area
      - owner
      - updated
  - type: table
    name: "Concluidas"
    filters:
      and:
        - 'status == "completed"'
    order:
      - file.name
      - updated
```

ADRs:

```yaml
filters:
  and:
    - 'type == "adr"'
views:
  - type: table
    name: "Por status"
    groupBy:
      property: status
      direction: ASC
    order:
      - file.name
      - status
      - date
      - area
      - related
```

## Migração por Fases

### Fase 1 - Preparar o vault

1. Abrir o repositório como vault no Obsidian.
2. Configurar arquivos excluídos: `.build/**`, `.git/**`, `.swiftpm/**`, `Tests/__Snapshots__/**`, `Tests/Fixtures/*.wav`, `*.xcuserdata/**`.
3. Criar `docs/_index.md`, `docs/_templates/` e `docs/_bases/`.
4. Manter `.obsidian/workspace.json` e caches fora do Git. Se for commitar settings, commitar só o mínimo reprodutível.

### Fase 2 - Normalizar documentos existentes

1. Adicionar YAML frontmatter aos Markdown atuais.
2. Verificar periodicamente README/PRD/AGENTS contra o código e manter a história do VAD apenas no ADR 003.
3. Deduplicar `AGENTS.md` e `CLAUDE.md` por meio de nota canônica em `docs/20-engenharia/`.
4. Criar MOCs: `MOC - zspeak`, `MOC - Arquitetura`, `MOC - Operacao`, `MOC - Backlog`.

### Fase 3 - Converter tarefas JSON

1. Converter cada `docs/tasks/TASK-*.json` em nota Markdown em `docs/40-backlog/`.
2. Manter os JSONs como arquivo legado ou movê-los para `docs/40-backlog/_archive-json/`.
3. Preservar `context`, `goal`, `acceptance`, `changes`, `followUps` e `changelog`.
4. Revalidar status de `TASK-002`, `TASK-003`, `TASK-004` contra o código antes de publicar o dashboard.

### Fase 4 - Criar dashboards e verificação

1. Criar `docs/_bases/adr.base`, `docs/_bases/backlog.base` e `docs/_bases/docs-health.base`.
2. Verificar links órfãos e não resolvidos no Obsidian.
3. Se Obsidian CLI estiver habilitado, usar `obsidian unresolved`, `obsidian links`, `obsidian base:query` para QA automatizado.
4. Adicionar uma checagem simples no CI para garantir frontmatter obrigatório em notas migradas.

## Boas Práticas

1. Separar documentação por necessidade do leitor: tutorial, how-to, referência e explicação. Para este projeto: README/onboarding como tutorial curto; build/test/release como how-to; APIs/permissões como referência; ADRs como explicação/decisão.
2. Usar propriedades para dados filtráveis e links para contexto. Exemplo: `status`, `area`, `owner` filtram; corpo do documento explica.
3. Não editar uma ADR antiga para fingir que ela sempre esteve certa. Quando uma decisão muda, marcar como `superseded` ou `revised` e criar/linkar uma sucessora.
4. Converter tarefas para Markdown porque Bases consulta propriedades de notas Markdown; JSON é ótimo para máquina, mas ruim como fonte principal no Obsidian.
5. Preferir nomes de arquivo legíveis e estáveis: `ADR-007 - Hotkey Global.md`, `TASK-011 - Overlay LLM Streaming.md`.
6. Manter notas de arquitetura linkadas ao código relevante por `code_paths` e por links no corpo.
7. Usar Canvas apenas para mapa visual do pipeline ou arquitetura. A fonte da verdade deve continuar sendo Markdown + propriedades.
8. Criar um checklist de saúde documental: docs sem `type`, docs sem `status`, ADRs sem `related`, tasks sem critério de aceite, notas sem links de saída.

## Fontes Consultadas

- Obsidian Help: Properties — https://obsidian.md/help/properties
- Obsidian Help: Bases — https://obsidian.md/help/bases
- Obsidian Help: Bases syntax — https://obsidian.md/help/bases/syntax
- Obsidian Help: Bases views — https://obsidian.md/help/bases/views
- Obsidian Help: Internal links — https://help.obsidian.md/Linking%20notes%20and%20files/Internal%20links
- Obsidian Help: Tags — https://help.obsidian.md/tags
- Obsidian Help: CLI — https://obsidian.md/help/cli
- Obsidian Changelog 1.12.7 — https://obsidian.md/changelog/
- Diataxis — https://diataxis.fr/
- MADR — https://adr.github.io/madr/
