#!/bin/zsh
# Garante que a identidade de assinatura é determinística entre builds.
#
# Regressão que este teste protege: quando a identidade muda, o requisito
# designado muda junto e o macOS invalida o grant de Acessibilidade — o toggle
# continua ligado nos Ajustes, mas AXIsProcessTrusted() devolve false e a
# hotkey/colagem param sem nenhuma mensagem.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/package_app.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Extrai o bloco real de resolução do package_app.sh — o teste não pode ter uma
# cópia da lógica, senão passa enquanto o script de verdade quebra.
sed -n '/# >>> bloco-identidade/,/# <<< bloco-identidade/p' "$SCRIPT" > "$WORK/block.sh"
if ! grep -q "pinned_identity()" "$WORK/block.sh"; then
  echo "FAIL: não consegui extrair o bloco de identidade do package_app.sh"
  exit 1
fi

falhas=0
check() {
  local nome="$1" obtido="$2" esperado="$3"
  if [[ "$obtido" == "$esperado" ]]; then
    echo "PASS $nome"
  else
    echo "FAIL $nome (obtido '$obtido', esperado '$esperado')"
    falhas=$((falhas + 1))
  fi
}

# Ambiente falso: HOME isolado e `security` dublado.
run_case() {
  local pin="$1" disponiveis="$2" explicito="$3"
  local casa="$WORK/home"
  rm -rf "$casa"; mkdir -p "$casa/.cache/zspeak/codesign"
  [[ -n "$pin" ]] && printf '%s' "$pin" > "$casa/.cache/zspeak/codesign/pinned-identity"

  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/security" <<EOF
#!/bin/zsh
printf '%s\n' $disponiveis
EOF
  chmod +x "$WORK/bin/security"

  HOME="$casa" PATH="$WORK/bin:$PATH" SIGNING_IDENTITY="$explicito" zsh -c '
    set -uo pipefail
    detect_identity() { echo "Detectada Nova"; }
    create_local_identity() { echo "Local Fallback"; }
    source "'"$WORK"'/block.sh" >/dev/null 2>&1
    echo "$SIGNING_IDENTITY"
  ' 2>/dev/null | tail -1
}

check "identidade fixada é reaproveitada" \
  "$(run_case 'Apple Development: Fulano' '"Apple Development: Fulano"' '')" \
  "Apple Development: Fulano"

check "pin cujo certificado sumiu do keychain é ignorado" \
  "$(run_case 'Certificado Removido' '"Outra Coisa"' '')" \
  "Detectada Nova"

check "sem pin usa a detecção normal" \
  "$(run_case '' '"Apple Development: Fulano"' '')" \
  "Detectada Nova"

check "SIGNING_IDENTITY explícito vence o pin" \
  "$(run_case 'Apple Development: Fulano' '"Apple Development: Fulano"' 'Escolha Manual')" \
  "Escolha Manual"

echo "TOTAL 4 | FALHAS $falhas"
[[ $falhas -eq 0 ]] || exit 1
echo "==> assinatura determinística OK"
