# ADR 011: Entradas em lote e áudios recentes da pasta de downloads

## Status

Parcialmente revertido (1.0.61).

O que valeu: fila em lote, entradas do Finder, lista da pasta de downloads e
fixação da identidade de assinatura. O que saiu: extensão do Chrome e servidor
HTTP local — ver **REVERTIDO** e **O que ficou no lugar**, no fim do documento.
As seções 3, 4 e 5 abaixo descrevem código que **não existe mais**; ficam como
registro do que foi tentado.

## Contexto

A ADR 010 entregou transcrição de arquivos, inclusive `.opus`/`.ogg` do
WhatsApp. Na prática o fluxo real esbarrou em duas fricções:

1. **Um arquivo por vez.** `AudioFileView` aceitava um único arquivo
   (`allowsMultipleSelection = false`, `providers.first`) e mantinha uma
   máquina de estados de um item só. Quem recebe uma conversa inteira em áudio
   baixa 9 arquivos e teria que repetir o fluxo 9 vezes.
2. **É preciso baixar antes.** Mesmo com o formato coberto, o usuário tem que
   baixar o áudio do WhatsApp, achar o arquivo e arrastar para o app.

O usuário deste repositório usa **WhatsApp Web no Chrome** (não há WhatsApp
Desktop instalado), o que abre um caminho que o app nativo não teria.

## Decisão

### 1. `FileTranscriptionQueue`: fila serial única

Uma fila `@MainActor @Observable` compartilhada por todas as entradas. Decisões:

- **Serial, não paralela.** O ASR roda no ANE, recurso único e também disputado
  pela gravação por microfone. Dois arquivos ao mesmo tempo trocariam
  throughput por contenção.
- **Prefetch de transcodificação.** Enquanto o item atual ocupa o ANE, o
  próximo que precisa de ffmpeg já é convertido para WAV na CPU. Num lote de
  `.opus` isso tira o ffmpeg do caminho crítico: só o primeiro arquivo paga a
  conversão em série.
- **Descarte de samples em modo texto corrido.** `FileTranscriptionResult`
  carrega o PCM inteiro (~115 MB por 30 min). Só o modo Reunião usa isso depois
  (reprodução de trecho por interlocutor), então em `.plain` os samples são
  zerados após persistir o histórico.
- **Clipboard consolidado.** Cada item roda com `copyToClipboard: false` e a
  fila copia no fim: um arquivo copia o texto puro; vários copiam o consolidado
  com o nome de cada um, restrito aos itens **daquela rodada**.

### 2. Quatro entradas para a mesma fila

| Entrada | Mecanismo |
|---|---|
| Janela "Transcrever arquivo" | `NSOpenPanel` com seleção múltipla + drop de N arquivos na janela inteira |
| Serviços do Finder | `NSServices` no Info.plist → `FileIngestEntryPoints.transcribeAudioFiles` |
| Abrir com | `CFBundleDocumentTypes` (rank `Alternate`) → `application(_:open:)` |
| Extensão do WhatsApp Web | `LocalIngestServer` em 127.0.0.1 |

`LSHandlerRank: Alternate` de propósito: o zspeak aparece em "Abrir com" sem
virar o app padrão de áudio do sistema.

### 3. `LocalIngestServer`: HTTP mínimo em 127.0.0.1

Servidor HTTP/1.1 escrito sobre `Network.framework` (sem dependência nova).

- `GET /health` — sem token, é como a extensão descobre se o app está rodando.
- `POST /transcribe` — bytes do áudio no corpo, nome em `X-ZSpeak-Filename`.
  Responde `202` com o ID do job.
- `GET /jobs/<id>` — status e texto, para a extensão exibir o resultado na
  própria conversa.

Postura de segurança:

- `requiredLocalEndpoint` amarrado ao loopback: nenhuma outra máquina da rede
  alcança. (Passar `on:` junto com `requiredLocalEndpoint` faz o listener falhar
  com `EINVAL` — o teste ponta a ponta existe por causa disso.)
- **Desligado por padrão.** Abrir porta local é opt-in explícito em
  Preferências → Integrações.
- Token de 32 caracteres obrigatório em tudo que não seja `/health`, comparado
  em tempo constante; token vazio nunca casa.
- Corpo limitado a 64 MB; nome de arquivo sanitizado contra path traversal;
  extensão precisa estar na lista de suportados.
- CORS liberado só para `chrome-extension://*` e `https://web.whatsapp.com`.

### 4. Preparação automática da extensão

Ligar a integração dispara `ChromeExtensionInstaller`:

1. copia a extensão do bundle para
   `~/Library/Application Support/zspeak/chrome-extension` — caminho estável
   fora do `.app`, que sobrevive a atualizações do zspeak (dentro do bundle, o
   Chrome perderia a extensão a cada release);
2. grava `config.json` com porta e token, lido pela extensão no boot — **é o
   que elimina o copiar/colar do token**;
3. reescreve esse `config.json` quando porta ou token mudam.

A sincronia é **arquivo a arquivo, sem apagar o diretório**: recriar a pasta
faria o Chrome marcar a extensão como quebrada. Arquivo idêntico é pulado para
não disparar recarga à toa.

**Limite explícito:** carregar a extensão no Chrome continua manual. O Chrome
só aceita instalação silenciosa da Web Store ou via política de empresa
(`ExtensionInstallForcelist`, que exige privilégio de administrador) — nenhum
app local contorna isso. `--load-extension` na linha de comando foi
descontinuado no canal estável e exigiria reiniciar o navegador do usuário.
Para zerar também esse passo, as saídas são publicar na Web Store ou
distribuir a política com admin.

### 5. Extensão do Chrome (MV3)

O áudio já está decodificado na página como `blob:` URL. A extensão lê esses
bytes e manda para o zspeak — **sem download e sem nada saindo da máquina**.

- A configuração vem de `config.json` (gravado pelo app). A tela de opções só
  serve de escape para porta diferente e marca `manual: true` no storage, que
  tem precedência sobre o automático.
- O `fetch` sai do **service worker**, não do content script: desde o Chrome 85
  requisição de content script carrega a origem da página e cairia no
  CORS/CSP do WhatsApp Web. O worker tem `host_permissions` para `127.0.0.1`.
- Permissões mínimas: `storage` + `http://127.0.0.1/*`. Nada de `<all_urls>`.
- O WhatsApp só materializa o blob quando a mensagem toca: a extensão dá play
  no mudo por um instante e restaura o player.

## Consequências

**Positivas**

- Lote de verdade: 9 áudios do WhatsApp viram uma fila, com progresso por item,
  cancelamento individual e "copiar tudo".
- O caminho mais curto ("clicar no áudio e o texto aparecer") passa a existir.
- O prefetch de ffmpeg some com a espera de conversão entre itens do lote.
- Serviços e "Abrir com" cobrem quem prefere o Finder, sem abrir o app antes.

**Negativas / riscos**

- A extensão depende do DOM do WhatsApp Web, que muda sem aviso. Mitigação: os
  seletores estão todos no objeto `SELECTORS` no topo de `content.js` e há
  teste garantindo que headers e porta batem com o servidor.
- A lista de conversas é virtualizada: "Transcrever todos" só alcança o que já
  está carregado na tela.
- Mais uma superfície local (porta HTTP). Mitigada por: desligada por padrão,
  loopback, token e limite de corpo.

## Alternativas consideradas

- **Instalar a extensão sozinho** — impossível sem Web Store ou política de
  admin (ver seção 4). O que sobrou de manual é um passo, uma vez por máquina.
- **Pasta observada (`~/Downloads`)** — 1 clique, mas transcreveria áudio que o
  usuário baixou por outro motivo. Descartada em favor das entradas explícitas.
- **Captura do áudio do sistema (ScreenCaptureKit)** — dispensa a extensão e
  serve para Meet/YouTube, mas roda em tempo real e exige a permissão de
  Gravação de Tela. Fica como evolução possível, não substitui esta.
- **Ler o cache do WhatsApp Desktop** — inviável aqui: o app nativo não está
  instalado, e o acesso ao container exigiria Acesso Total ao Disco.

## 5. Botão "Abrir o Chrome no lugar certo" (1.0.55)

O usuário pediu um clique único que fizesse todo o setup. Ele não existe, e a
causa é do Chrome, não do zspeak:

- o `--load-extension` foi **removido no Chrome 137**;
- no macOS, instalação por métodos externos (`external_crx`, `external_update_url`)
  só é aceita para extensões hospedadas na Web Store;
- instalação silenciosa fora da loja exige `ExtensionInstallForcelist`, que é
  política de empresa e precisa de admin.

Verificado na máquina do usuário (Chrome 152): `--help` não lista mais
`load-extension` e não há política gerenciada instalada.

O que o botão automatiza, então, é tudo que sobra:

1. reconfere a extensão preparada (`ChromeExtensionInstaller`);
2. revela a pasta no Finder, pronta para arrastar;
3. copia o caminho para o clipboard (dá `Cmd+Shift+G` + `Cmd+V` no seletor);
4. abre `chrome://extensions`.

Detalhe que decidiu a implementação: `chrome://` **não é um esquema registrado
no LaunchServices**, então `NSWorkspace.open(_:)` sozinho não resolve. É preciso
indicar o app de destino — `NSWorkspace.open(_:withApplicationAt:configuration:)`,
equivalente ao `open -a "Google Chrome" chrome://extensions/`. Isso funciona com
o Chrome já aberto e **não pede permissão de Automação**; a alternativa via
AppleScript funcionava mas dispararia um prompt de TCC.

Só a família Chrome entra em `supportedBrowsers`: Edge e Brave bloqueiam o
esquema `chrome://` (usam `edge://` e `brave://`), então listá-los daria um botão
que abre o navegador numa página de erro.

Para eliminar os dois cliques restantes existem exatamente dois caminhos:
publicar a extensão na Chrome Web Store, ou pedir ao TI a política de empresa.
Uma terceira via, que dispensa o Chrome por completo, continua em aberto: a
Fase 2B (captura do áudio do sistema via ScreenCaptureKit).

## 6. Detecção de bolhas resistente a mudança de DOM (1.0.56)

A extensão carregou no Chrome, o painel flutuante apareceu — e nenhum botão
"Transcrever" surgiu nas mensagens. Causa: `bubbles()` dependia de **dois**
pontos únicos de falha em série:

1. `document.querySelector("#main")` — sem essa raiz, retorno vazio imediato;
2. `root.querySelectorAll("audio")` — nas versões novas do WhatsApp Web o
   elemento `<audio>` **só nasce depois do primeiro play**, então a lista vinha
   vazia mesmo com a conversa cheia de mensagens de voz.

Reescrito com camadas de fallback:

- `conversationRoots` é uma lista (`#main`, `data-testid`, `aria-label`, `main`)
  com `document.body` como último recurso;
- `bubbles()` soma duas estratégias e deduplica por linha: elementos `<audio>`
  presentes **e** controles de play (`aria-label`, `data-icon`);
- `closestRow()` tenta `[data-id]`, depois `[role="row"]`, depois sobe até 6
  níveis procurando âncora;
- `resolveAudio()` clica no play quando não há `<audio>` e espera o player
  nascer. O laço de mudo roda a cada **10ms** (e não nos 120ms do `waitFor`)
  porque a diferença prática é entre um clique inaudível e um trecho da mensagem
  tocando alto na sala.

Além disso, `diagnose()` / `zspeakDiag()` e `diagnosisMessage()`: quando nada é
encontrado, o painel diz **qual camada quebrou** em vez de "nenhum áudio". Sem
isso, cada mudança de DOM do WhatsApp vira uma sessão de adivinhação.

### Teste sem dependência nova

O projeto é Swift e não tem runner de JS. Em vez de adicionar jsdom, os testes
rodam no **Chrome headless já instalado**: `chrome-extension/tests/run.sh` abre
`detection.html` com `--dump-dom`, e a página monta 5 cenários de DOM (marcação
antiga com `<audio>`, marcação nova só com botão, `data-icon`, linha com os dois
— que não pode contar em dobro — e conversa vazia) e imprime PASS/FAIL.

Regressão TDD validada: com o comportamento antigo restaurado, 3 dos 8 casos
falham, exatamente os que reproduzem o sintoma relatado (0 bolhas).

## 7. Diagnóstico que volta sozinho (1.0.57)

Depois de duas rodadas de conserto às cegas, ficou claro que o gargalo não era o
código: era não ter acesso ao DOM real. Pedir ao usuário para colar saída de
console não escala e é frágil.

Solução: a extensão manda o retrato estrutural para o próprio zspeak.

- `POST /diag` no `LocalIngestServer` (mesmo token, teto de 256 KB — a rota não
  pode virar um canal de upload paralelo);
- `LocalIngestController.storeDiagnostics` grava em
  `~/Library/Application Support/zspeak/whatsapp-dom-diagnostico.json`;
- `content.js` chama `reportIfBlind()` 3s após o boot **quando não achou
  nenhuma bolha**, e também quando o usuário clica em "Transcrever todos" sem
  resultado. `window.zspeakSendDiag()` força o envio.

Fronteira de privacidade, deliberada: o relatório carrega apenas nomes de tag,
classes, nomes de atributo, valores de `data-icon`/`role`/`data-testid` e
rótulos de botão que casem com `AUDIO_LABEL_PATTERN`. Nunca `textContent` e
nunca `data-pre-plain-text` — esse atributo contém o nome de quem enviou e o
horário da mensagem. O destino é sempre `127.0.0.1`.

---

## REVERTIDO (2026-08-31) — a integração com o navegador saiu

Tudo que trata de extensão do Chrome, servidor HTTP local e `chrome://extensions`
nas seções acima **foi removido do código**. O texto fica como registro do que
foi tentado e do porquê não vingou.

Motivo: o custo de manutenção não se pagava. Em sequência, na mesma tarde:

1. o Chrome não deixa nenhum app carregar extensão desempacotada (removeu o
   `--load-extension` na versão 137), então sobrava sempre um passo manual;
2. a detecção de bolhas quebrou porque o WhatsApp Web abandonou o `#main` e o
   `<audio>` por mensagem;
3. depois de consertada a detecção, não havia mais **nenhum** elemento de mídia
   de onde ler os bytes — foi preciso interceptar `URL.createObjectURL` no mundo
   da página;
4. e cada passo desses depende de marcação que o WhatsApp muda sem aviso.

Uma integração que exige engenharia reversa do DOM de terceiros a cada
atualização não é uma base sobre a qual construir.

## O que ficou no lugar (1.0.61)

O fluxo real do usuário é: baixar os áudios e transcrever. Então a tela
**Transcrever arquivo** passou a ter duas abas por ORIGEM — **Na pasta** e
**Anexados** — e a primeira é alimentada por `RecentAudioScanner`:

- varre a pasta de downloads (trocável) e lista **do mais novo para o mais
  antigo**, com a hora de chegada;
- `FolderWatcher` observa a pasta com `DispatchSourceFileSystemObject`, com
  debounce de 400ms — um download dispara vários eventos (arquivo `.download`,
  renomeação, atributo) e sem o debounce a pasta seria revarrida meia dúzia de
  vezes por arquivo;
- seleção múltipla alimenta a mesma `FileTranscriptionQueue` já existente;
- o resultado abre embaixo da própria linha, em fonte pequena e com botão de
  copiar, em vez de mandar o usuário a um painel de detalhe separado. A tela
  também está nas Preferências (**Transcrever Arquivo**), que é onde o usuário
  foi procurar.

Decisão de data que importa: a ordenação usa `addedToDirectoryDateKey`
(**chegada na pasta**), não `creationDate`. Num áudio do WhatsApp encaminhado, o
`creationDate` é a data da gravação original — um áudio de um ano atrás baixado
agora afundaria no fim da lista, que é o oposto do esperado. Há teste para
exatamente esse caso.

Sobrevive da rodada anterior, porque conserta bugs reais e independe do
navegador: a `FileTranscriptionQueue` (lote + prefetch de transcodificação), as
entradas do Finder (`NSServices` e "Abrir com"), e a fixação da identidade de
assinatura em `package_app.sh` (ver seção sobre Acessibilidade).

