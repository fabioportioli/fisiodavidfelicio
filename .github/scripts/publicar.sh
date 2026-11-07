#!/usr/bin/env bash
# Publica por FTPS só o que mudou entre o commit que está no servidor e o commit atual.
#
#  - O servidor guarda, no arquivo .deploy-version, o SHA do último deploy que terminou 100% certo.
#  - A cada deploy: lê esse SHA, monta o pacote daquele commit e o do commit atual,
#    compara os dois, envia só o que mudou e apaga só o que foi removido do projeto.
#  - Só depois de tudo enviado o .deploy-version é atualizado. Se algo falhar, o SHA antigo
#    continua lá e o próximo deploy refaz a diferença completa.
#  - Sem .deploy-version (primeiro deploy), com valor inválido ou com commit que não existe
#    mais no histórico: envia o pacote inteiro (sem apagar nada).
#  - Arquivos do servidor que nunca estiveram no pacote (.well-known, .ftpquota, .htaccess
#    criado à mão etc.) jamais são tocados.
#
# Variáveis: FTP_SERVER FTP_USER FTP_PASSWORD FTP_DIR [FTP_PORT]
#            MODO=diff|tudo    SIMULAR=true|false
# Nunca imprime credenciais.
set -euo pipefail

REPO="$(git rev-parse --show-toplevel)"
MODO="${MODO:-diff}"
SIMULAR="${SIMULAR:-false}"
PORTA="${FTP_PORT:-21}"
VERSAO_ARQ=".deploy-version"
TMP="$(mktemp -d)"
cleanup() {
  git -C "$REPO" worktree remove --force "$TMP/antigo-src" >/dev/null 2>&1 || true
  rm -rf "$TMP"
  git -C "$REPO" worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT

erro() { echo "ERRO: $*" >&2; exit 1; }
conta() { wc -l < "$1" | tr -d ' '; }

# ---------------------------------------------------------------- transporte
if [ -n "${DEPLOY_TEST_DIR:-}" ]; then
  # somente para testes locais: o "servidor" é uma pasta
  ler_versao() { [ -f "$DEPLOY_TEST_DIR/$VERSAO_ARQ" ] && cat "$DEPLOY_TEST_DIR/$VERSAO_ARQ" || true; }
  ftp_put() { [ "$2" = "${DEPLOY_TEST_FALHAR:-}" ] && return 1; mkdir -p "$(dirname "$DEPLOY_TEST_DIR/$2")"; cp "$1" "$DEPLOY_TEST_DIR/$2"; }
  ftp_del() { rm -f "$DEPLOY_TEST_DIR/$1"; }
else
  for v in FTP_SERVER FTP_USER FTP_PASSWORD; do
    [ -n "${!v:-}" ] || erro "secret $v não está definido"
  done
  PREFIXO="${FTP_DIR:-/}"; PREFIXO="${PREFIXO#/}"
  [ -z "$PREFIXO" ] || PREFIXO="${PREFIXO%/}/"
  BASE="ftp://${FTP_SERVER}:${PORTA}/"
  NETRC="$TMP/netrc"
  printf 'machine %s login %s password %s\n' "$FTP_SERVER" "$FTP_USER" "$FTP_PASSWORD" > "$NETRC"
  chmod 600 "$NETRC"
  CURL=(curl -sS --ssl-reqd --netrc-file "$NETRC")
  urlenc() { python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe="/"))' "$1"; }

  ler_versao() {
    local out rc
    set +e
    out="$("${CURL[@]}" --max-time 60 "${BASE}$(urlenc "${PREFIXO}${VERSAO_ARQ}")" 2>"$TMP/err")"
    rc=$?
    set -e
    case "$rc" in
      0) printf '%s' "$out" ;;
      78|19) ;;   # arquivo não existe: primeiro deploy
      *) erro "não consegui falar com o servidor FTP (curl código $rc)" ;;
    esac
  }
  ftp_put() { "${CURL[@]}" --fail --ftp-create-dirs --max-time 600 -T "$1" "${BASE}$(urlenc "${PREFIXO}$2")"; }
  ftp_del() { "${CURL[@]}" --max-time 60 -Q "-DELE ${PREFIXO}$1" -o /dev/null "$BASE"; }
fi

tentar() {  # tentar CMD... (3 tentativas)
  local n=0
  until "$@"; do
    n=$((n + 1)); [ "$n" -ge 3 ] && return 1
    sleep 3
  done
}

# ---------------------------------------------------------------- pacote do commit atual
SHA_NOVO="$(git -C "$REPO" rev-parse HEAD)"
NOVO="$TMP/novo"
ANTIGO="$TMP/antigo"
echo "Commit a publicar: ${SHA_NOVO:0:7}"
( cd "$REPO" && bash "$REPO/.github/scripts/montar-pacote.sh" "$NOVO" ) > "$TMP/montagem-novo.log" 2>&1 \
  || { cat "$TMP/montagem-novo.log"; erro "falha ao montar o pacote do commit atual"; }

# ---------------------------------------------------------------- versão no servidor
SERVIDOR="$(ler_versao | tr -d '[:space:]')"
MODO_REAL="tudo"

if [ "$MODO" = "diff" ]; then
  if [ -z "$SERVIDOR" ]; then
    echo "Servidor sem .deploy-version (primeiro deploy): vai enviar o pacote inteiro."
  elif ! [[ "$SERVIDOR" =~ ^[0-9a-f]{40}$ ]]; then
    echo "AVISO: .deploy-version com conteúdo inválido: vai enviar o pacote inteiro."
  elif [ "$SERVIDOR" = "$SHA_NOVO" ]; then
    echo "O servidor já está no commit ${SHA_NOVO:0:7}. Nada a fazer."
    exit 0
  elif ! git -C "$REPO" cat-file -e "${SERVIDOR}^{commit}" 2>/dev/null; then
    echo "AVISO: o commit do servidor (${SERVIDOR:0:7}) não existe neste histórico: vai enviar o pacote inteiro."
  else
    echo "Servidor está em ${SERVIDOR:0:7}. Comparando com ${SHA_NOVO:0:7}."
    git -C "$REPO" worktree add --detach "$TMP/antigo-src" "$SERVIDOR" >/dev/null 2>&1 || true
    if [ -d "$TMP/antigo-src" ] \
       && ( cd "$TMP/antigo-src" && bash "$REPO/.github/scripts/montar-pacote.sh" "$ANTIGO" ) > "$TMP/montagem-antigo.log" 2>&1; then
      MODO_REAL="diff"
    else
      echo "AVISO: não consegui montar o pacote do commit ${SERVIDOR:0:7}: vai enviar o pacote inteiro."
    fi
  fi
else
  echo "Modo 'tudo': reenvia o pacote inteiro."
fi

# ---------------------------------------------------------------- o que enviar / apagar
( cd "$NOVO" && find . -type f -printf '%P\n' | LC_ALL=C sort ) > "$TMP/novos.txt"
: > "$TMP/enviar.txt"; : > "$TMP/apagar.txt"

if [ "$MODO_REAL" = "diff" ]; then
  ( cd "$ANTIGO" && find . -type f -printf '%P\n' | LC_ALL=C sort ) > "$TMP/antigos.txt"
  while IFS= read -r f; do
    if [ ! -f "$ANTIGO/$f" ] || ! cmp -s "$NOVO/$f" "$ANTIGO/$f"; then
      printf '%s\n' "$f" >> "$TMP/enviar.txt"
    fi
  done < "$TMP/novos.txt"
  LC_ALL=C comm -23 "$TMP/antigos.txt" "$TMP/novos.txt" | grep -v -E '^(\.well-known/|\.ftpquota$|\.deploy-version$)' > "$TMP/apagar.txt" || true
else
  cp "$TMP/novos.txt" "$TMP/enviar.txt"
fi

# ordem: tudo que não é página primeiro, páginas depois, index.html por último
{
  grep -v -E '\.html?$' "$TMP/enviar.txt" || true
  grep -E '\.html?$' "$TMP/enviar.txt" | grep -v -x 'index.html' || true
  grep -x 'index.html' "$TMP/enviar.txt" || true
} > "$TMP/ordem.txt"

echo "Plano (${MODO_REAL}): $(conta "$TMP/ordem.txt") arquivo(s) para enviar, $(conta "$TMP/apagar.txt") para apagar."
awk 'NR<=200 { print "  + " $0 }' "$TMP/ordem.txt"
awk 'NR<=200 { print "  - " $0 }' "$TMP/apagar.txt"

if [ "$SIMULAR" = "true" ]; then
  echo "Simulação: nada foi enviado nem apagado, e o .deploy-version não foi alterado."
  exit 0
fi

# ---------------------------------------------------------------- enviar, apagar, registrar versão
while IFS= read -r f; do
  [ -n "$f" ] || continue
  echo "  enviando $f"
  tentar ftp_put "$NOVO/$f" "$f" || erro "falha ao enviar $f. O .deploy-version NÃO foi atualizado; rode de novo."
done < "$TMP/ordem.txt"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  echo "  apagando $f"
  tentar ftp_del "$f" || erro "falha ao apagar $f. O .deploy-version NÃO foi atualizado; rode de novo."
done < "$TMP/apagar.txt"

printf '%s\n' "$SHA_NOVO" > "$TMP/versao"
tentar ftp_put "$TMP/versao" "$VERSAO_ARQ" || erro "arquivos enviados, mas não consegui gravar o .deploy-version"
echo "Pronto: servidor agora está no commit ${SHA_NOVO:0:7}."
