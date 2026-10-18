# Site do zspeak

Site local em React com API Node para apresentação do produto e acesso autenticado aos downloads. O áudio, as transcrições, o histórico, o vocabulário e os modelos continuam no aplicativo desktop; a API guarda apenas a conta e a sessão.

## Rodar localmente

Requer Node.js 22 ou superior.

```bash
cd site
npm install
npm run dev -- --host 127.0.0.1 --port 4173 --strictPort
```

- Site: `http://127.0.0.1:4173`
- API: `http://127.0.0.1:4174`
- Dados locais: `site/data/zspeak.json` (ignorado pelo Git)

## Validar

```bash
npm test
npm run build
```

O workflow `CI Site` repete instalação pelo lockfile, auditoria de dependências,
testes de API/interface e build em cada PR e alteração na `main`.

As variáveis aceitas estão em `.env.example`. URLs de download só aparecem no catálogo quando uma URL HTTPS explícita é configurada. Até a aprovação do deploy na VPS, nenhum artefato é publicado.

## Segurança do MVP

- senha com `scrypt`;
- token de sessão persistido apenas como hash;
- cookie `HttpOnly`, `SameSite=Strict` e `Secure` em produção;
- verificação same-origin para CORS/CSRF;
- rate limit por IP e por combinação IP/conta;
- downloads e catálogo protegidos por sessão e entitlement.

O armazenamento JSON suporta uma única instância da API. Falhas de gravação não
confirmam alterações apenas em memória e falhas ao emitir sessão respondem com
erro HTTP. A publicação na VPS ainda exige servir `dist/` e encaminhar `/api/`
para o processo Node no mesmo domínio; este commit não realiza esse deploy.

O workflow antigo do GitHub Pages foi removido porque ele não executa a API Node e não atende ao login obrigatório. A publicação futura deve usar a stack completa na VPS.
