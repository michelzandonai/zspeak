# Design QA — novo site zspeak

**Source visual truth path:** `site/docs/qa/current-site-reference.png`
**Implementation screenshot paths:** `site/docs/qa/new-site-hero-desktop.png`, `site/docs/qa/new-site-mobile.png`, `site/docs/qa/new-site-platforms-section.png`, `site/docs/qa/new-site-privacy-section.png`, `site/docs/qa/new-site-download-authenticated.png`
**Viewport:** desktop padrão do navegador (1265 × 708 observado) e mobile 390 × 844
**State:** público, cadastro, usuário autenticado, catálogo de downloads e menu mobile

## Full-view comparison evidence

A referência e a implementação foram abertas juntas para comparação. A nova versão preserva a composição editorial da fonte: papel quente, tipografia sans pesada, acentos mono verdes, navegação compacta, hero em duas colunas e superfícies escuras para demonstrar o produto. A implementação substitui a ilustração antiga por capturas reais e recém-regeneradas do aplicativo, troca o CTA genérico por cadastro/login e remove benchmark e promessas incompatíveis com a conta obrigatória.

O screenshot `new-site-fullpage-browser-artifact.png` registrou repetição causada pela captura `fullPage` do navegador com header sticky; por isso ele não foi usado como evidência de layout. A página foi inspecionada por capturas de viewport direcionadas a cada seção e pelos breakpoints desktop/mobile.

## Focused region comparison evidence

- **Hero:** `current-site-reference.png` versus `new-site-hero-desktop.png`. Hierarquia, margens, proporção das colunas, paleta e ritmo da referência foram preservados; a nova captura real do tray substitui o mock demonstrativo.
- **Plataformas:** `new-site-platforms-section.png`. macOS e Windows permanecem em cartões pareados, mas Windows agora está explicitamente marcado como em desenvolvimento e não usa captura fabricada.
- **Privacidade:** `new-site-privacy-section.png`. A mensagem foi corrigida para separar a conta online do conteúdo local, com lista legível dos dados que ficam no computador.
- **Autenticação:** `new-site-download-authenticated.png`. Modal, hierarquia, foco visual e estados sem artefatos publicados seguem o mesmo sistema visual.
- **Mobile:** `new-site-mobile.png`. Conteúdo cabe em 390 px, sem scroll horizontal, texto cortado ou CTA fora da tela.

## Required fidelity surfaces

- **Fonts and typography:** stack Inter/system e mono preservada; pesos, escalas, line-height e wrapping mantêm a hierarquia editorial da referência. Nenhum truncamento observado.
- **Spacing and layout rhythm:** shell, hero, galerias, cards, modais e CTA mantêm espaçamento consistente; desktop e mobile não apresentaram overflow horizontal.
- **Colors and visual tokens:** papel `#f4f0e7`, night `#08120f`, verde principal e bordas neutras permanecem coerentes com a referência e têm contraste adequado nos estados inspecionados.
- **Image quality and asset fidelity:** logo real convertido de `Resources/zspeak.icns`; quatro snapshots reais do macOS em resolução 2×; nenhum mockup Windows ou placeholder visual foi usado.
- **Copy and content:** todo conteúdo web legado incompatível foi removido. A comunicação atual afirma corretamente que somente a conta é online e que Windows continua em desenvolvimento.

## Comparison history

1. **[P1] Cadastro falhava no ambiente local através do proxy Vite.** Evidência: o formulário retornava `Origem não permitida` mesmo vindo do site local. Causa: o proxy encaminhava `Host` da API e `Origin` do frontend, produzindo origens diferentes. Correção: o proxy de desenvolvimento passou a normalizar `Host` e `Origin` para o target local. Evidência pós-fix: cadastro, catálogo autenticado, logout e novo login concluídos pelo navegador; regressão automatizada em `server/dev-proxy.test.js`.
2. **[P2] Captura `fullPage` repetia regiões por interação com header sticky.** Não era defeito da página. Correção de evidência: QA passou a usar capturas de viewport por seção e breakpoint; nenhum ajuste de produto necessário.

## Primary interactions tested

- navegação por âncoras;
- abertura e fechamento do cadastro;
- cadastro real com cookie de sessão;
- catálogo protegido após autenticação;
- logout e login da conta criada;
- carrossel coberto por teste de componente;
- menu mobile aberto em 390 × 844;
- console do navegador verificado: nenhum erro ou warning.

## Findings

Nenhuma diferença P0, P1 ou P2 permanece. As mudanças visuais em relação à referência são intencionais e correspondem ao novo posicionamento local, à autenticação obrigatória e ao uso de capturas reais.

## Open Questions

- URLs dos instaladores continuarão ausentes até a aprovação da publicação na VPS.
- Uma captura real do Windows deve substituir ou complementar o cartão assim que for produzida e validada na máquina Windows.

## Implementation Checklist

- [x] Identidade visual e logo preservados.
- [x] Capturas reais do macOS regeneradas e incorporadas.
- [x] Windows identificado como em desenvolvimento.
- [x] Cadastro, login, logout e downloads protegidos validados.
- [x] Desktop, mobile, interações e console validados.
- [x] P0-P2 zerados.

## Follow-up Polish

- [P3] Adicionar captura real do Windows depois do gate visual no computador Windows.

final result: passed

## Revisão para integração — 18/10/2026

- As capturas acima registram a implementação anterior e continuam como referência;
  o texto do catálogo foi simplificado para não expor detalhes de deploy ao usuário.
- Inspeção dos assets macOS: somente exemplos demonstrativos de transcrição,
  sem credenciais, conteúdo de cliente ou sessões reais nas imagens públicas.
- `npm ci`, `npm test` e `npm run build` passaram: 17 testes de API/armazenamento/proxy
  e 4 testes de componente. As falhas de emissão de sessão e gravação foram
  cobertas por regressões automatizadas em `server/app.test.js` e `server/store.test.js`.
- `npm audit`: zero vulnerabilidades após a atualização do Vitest e do lockfile.
- O workflow `CI Site` passa a repetir esses gates. O deploy VPS permanece separado
  da integração do código na `main`.
