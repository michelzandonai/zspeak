# PRD: zspeak MVP — Transcrição por Voz Local para Desenvolvedores

## 1. Visão do Produto

**zspeak** é um app de ditado por voz para macOS que transcreve fala em texto e insere automaticamente no app ativo. Focado em desenvolvedores brasileiros que falam português com termos técnicos em inglês.

Diferencial: 100% local, sem cloud, sem API keys, sem assinatura. Roda no Apple Silicon usando o mesmo motor de transcrição do Spokenly.

---

## 2. Persona

**Michel** — Desenvolvedor de software brasileiro.

- Usa macOS com Apple Silicon diariamente
- Fala português brasileiro misturado com termos técnicos em inglês
- Quer ditar texto enquanto desenvolve (mensagens, commits, docs, prompts para IA)
- Valoriza privacidade (áudio nunca sai do dispositivo)
- Teve projeto anterior abandonado por complexidade — quer algo simples que funcione

---

## 3. Problema

Desenvolvedores brasileiros precisam digitar muito texto ao longo do dia: mensagens, documentação, commits, PRs, prompts para ferramentas de IA. Digitar é lento (~40-80 WPM) comparado a falar (~150-220 WPM). Apps de ditado existentes ou são cloud-only (privacidade), ou não reconhecem termos técnicos em inglês quando o usuário fala português, ou são complexos demais.

---

## 4. Solução

App de menubar que:

1. O usuário pressiona um atalho de teclado (toggle)
2. Fala normalmente em português, incluindo termos técnicos em inglês
3. Pressiona o atalho novamente
4. O texto transcrito aparece automaticamente onde o cursor está

---

## 5. Funcionalidades MVP

### 5.1 Transcrição por voz (P0 — Must Have)

- Transcrever fala em português brasileiro com termos técnicos em inglês
- Modelo Parakeet TDT 0.6B V3 via CoreML/Apple Neural Engine
- 100% local, sem internet
- Não gerar texto quando há silêncio (zero alucinação)
- Reconhecer termos: GitHub, git pull, deploy, branch, merge, API, endpoint, TypeScript, Docker, Kubernetes, CI/CD, pull request, commit, etc.

### 5.2 Toggle hotkey (P0 — Must Have)

- Atalho de teclado global (funciona em qualquer app)
- Toggle: pressionar para iniciar, pressionar novamente para parar
- Atalho padrão: Cmd+Shift+Space
- Customizável pelo usuário nas configurações

### 5.3 Inserção automática de texto (P0 — Must Have)

- Texto transcrito inserido automaticamente no app em foco
- Via clipboard + Cmd+V simulado
- Funcionar em: VS Code, Terminal, Slack, browser, Notes, qualquer text field
- Restaurar clipboard anterior após inserção

### 5.4 Indicador visual (P0 — Must Have)

- Ícone no menu bar (tray)
- Estados visuais:
  - **Idle**: ícone cinza — pronto para usar
  - **Gravando**: ícone vermelho — captando áudio
  - **Processando**: ícone amarelo — transcrevendo
- App escondido do Dock (vive apenas no menu bar)

### 5.5 Detecção de atividade vocal (P0 — Must Have)

- Silero VAD detecta início e fim de fala
- Silêncio > 500ms marca fim de fala
- Buffer de áudio acumula somente durante fala
- Silêncio puro nunca é enviado para transcrição

### 5.6 Configurações (P1 — Should Have)

- Tela de configurações acessível pelo menu do tray
- Customizar atalho de teclado
- Ligar/desligar som de feedback
- Auto-start com sistema
- Escolher microfone (se múltiplos disponíveis)

### 5.7 Feedback sonoro (P2 — Nice to Have)

- Som sutil ao iniciar gravação
- Som sutil ao parar gravação
- Configurável (on/off)

### 5.8 Histórico (P2 — Nice to Have)

- Últimas N transcrições acessíveis pelo menu do tray
- Copiar transcrição anterior para clipboard

---

## 6. Requisitos Não-Funcionais

### 6.1 Performance

- Transcrição completa em < 1 segundo após fim da fala
- Startup do app em < 3 segundos (modelo já baixado)
- Primeiro uso: download do modelo em < 2 minutos (496 MB)
- Idle: < 50 MB RAM, < 1% CPU

### 6.2 Privacidade

- Zero dados enviados para internet
- Zero telemetria
- Áudio processado em memória, nunca salvo em disco (exceto se o usuário ativar histórico)
- Sem conta, sem login, sem API keys

### 6.3 Compatibilidade

- macOS 14.0+ (Sonoma)
- Apple Silicon (M1, M2, M3, M4 e variantes)
- NÃO suporta Intel Macs (CoreML/ANE requer Apple Silicon)

### 6.4 Acessibilidade

- Requer permissão de Microfone (solicitada na primeira gravação)
- Requer permissão de Acessibilidade (solicitada na primeira inserção de texto)
- Guia de permissões na primeira execução

---

## 7. Fluxo do Usuário

### Primeiro uso

1. Abrir zspeak pela primeira vez
2. Modelo Parakeet TDT baixa automaticamente (~496 MB, ~1-2 min)
3. App solicita permissão de microfone → usuário autoriza
4. App solicita permissão de acessibilidade → usuário autoriza nas Configurações do Sistema
5. Ícone cinza aparece no menu bar → pronto para usar

### Uso normal

1. Usuário está em qualquer app (VS Code, Slack, browser...)
2. Cursor posicionado onde quer digitar
3. Pressiona Cmd+Shift+Space → ícone fica vermelho
4. Fala: "Eu vou fazer um deploy do branch main e depois abrir um pull request"
5. Pressiona Cmd+Shift+Space → ícone fica amarelo (processando)
6. ~0.5s depois → texto aparece onde o cursor estava, ícone volta a cinza

### Silêncio

1. Usuário pressiona hotkey
2. Não fala nada (ou fica pensando)
3. Pressiona hotkey novamente
4. Nenhum texto é inserido (VAD detectou que não houve fala)

---

## 8. Critérios de Aceite (MVP)

| ID    | Critério                        | Como testar                                                        |
|-------|---------------------------------|--------------------------------------------------------------------|
| CA-01 | Transcreve PT-BR corretamente   | Ditar 10 frases em português, > 90% de acurácia                   |
| CA-02 | Reconhece termos técnicos EN    | Ditar "git pull", "deploy", "API endpoint" → texto correto        |
| CA-03 | Não alucina em silêncio         | Toggle ON → silêncio 10s → Toggle OFF → nenhum texto inserido     |
| CA-04 | Toggle hotkey funciona globalmente | Testar em VS Code, Terminal, browser, Notes                     |
| CA-05 | Texto inserido no app ativo     | Cursor no VS Code, ditar → texto aparece no VS Code               |
| CA-06 | Indicador visual correto        | Ícone muda: cinza → vermelho → amarelo → cinza                    |
| CA-07 | Latência < 1s                   | Medir tempo entre fim da fala e texto inserido                     |
| CA-08 | Funciona offline                | Desconectar Wi-Fi, testar transcrição completa                     |
| CA-09 | Hotkey customizável             | Mudar atalho nas configurações, verificar que funciona             |
| CA-10 | Restaura clipboard              | Copiar algo, ditar texto, verificar que clipboard original volta   |

---

## 9. Fora do Escopo (MVP)

- Múltiplos modelos de transcrição
- Modo de comandos de voz (controlar Mac por voz)
- Pós-processamento com LLM (GPT, Claude)
- iOS / iPadOS
- Windows / Linux
- MCP Server para ferramentas de IA
- Agent Mode
- Text-to-Speech
- Speaker Diarization
- Gravação de áudio do sistema
- Transcrição de arquivos de áudio/vídeo

---

## 10. Métricas de Sucesso

| Métrica                          | Meta                            |
|----------------------------------|---------------------------------|
| Acurácia PT-BR                   | > 90% (avaliação manual)        |
| Acurácia termos técnicos         | > 95% (top 20 termos)           |
| Latência fim-fala → texto        | < 1 segundo                     |
| Alucinação em silêncio           | 0 ocorrências em 100 testes     |
| RAM idle                         | < 50 MB                         |
| Tamanho do app (sem modelo)      | < 10 MB                         |
