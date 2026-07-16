# Prompt para sincronizar o zspeak no Mac

Copie o texto abaixo para o Codex executado no Mac. Ele sincroniza a `main` sem
apagar alterações locais, lê os documentos relevantes e valida que o aplicativo
macOS continua íntegro depois da inclusão do Windows e do site.

```text
Estou no macOS e quero sincronizar a versão mais recente do zspeak.

Repositório: https://github.com/michelzandonai/zspeak.git

Trabalhe com cuidado e preserve qualquer alteração local preexistente. Primeiro
verifique `pwd`, `git status`, branch e remote. Se o repositório ainda não estiver
clonado no diretório escolhido, execute:

git clone https://github.com/michelzandonai/zspeak.git
cd zspeak

Se ele já estiver clonado, entre no diretório. Se a árvore estiver limpa, execute:

git fetch origin --prune
git switch main
git pull --ff-only origin main

Se houver alterações locais, não faça reset, checkout destrutivo, stash ou merge
automático: mostre o status e explique o que impede o pull seguro.

Depois da sincronização, leia integralmente, nesta ordem:

1. AGENTS.md
2. README.md
3. docs/HANDOFF-WINDOWS.md
4. windows/README.md
5. docs/versioning.md
6. Package.swift
7. site/index.html

Confirme o commit atual com `git log -1 --oneline` e resuma:

- o estado do app macOS;
- o que foi entregue no Windows;
- como o site oficial é publicado;
- a versão atual;
- diferenças relevantes entre macOS e Windows.

No Mac, resolva as dependências e valide o app existente com:

swift package resolve
xcodebuild -scheme zspeak -configuration Debug -destination 'platform=macOS' build
swift test

Não altere o código, não gere release e não faça commit ou push sem eu pedir.
Se alguma validação falhar, investigue e apresente o comando, o erro e a causa
provável sem apagar mudanças locais.
```
