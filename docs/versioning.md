# Versionamento do zspeak

Versão atual do app: `1.0.38`.

## Regra padrão

A cada alteração implementada e entregue no projeto, incrementar sempre o último nível da versão:

- `1.0.3` -> `1.0.4`
- `1.0.4` -> `1.0.5`
- `1.0.5` -> `1.0.6`

Essa é a regra padrão até o usuário pedir explicitamente para incrementar o segundo nível.

## Segundo nível

Quando o usuário pedir para incrementar o segundo nível, subir a versão minor e reiniciar o patch:

- `1.0.x` -> `1.1.0`
- `1.1.x` -> `1.2.0`

## Arquivos de versão

Atualizar `zspeak/Info.plist` em conjunto:

- `CFBundleShortVersionString`: versão pública, como `1.0.3`.
- `CFBundleVersion`: build interno correspondente, como `103`.
