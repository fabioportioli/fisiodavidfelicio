#!/usr/bin/env bash
# Monta em $1 só o que o servidor precisa. Roda na raiz do projeto (pasta atual).
# Site de página única com CSS e JS embutidos no index.html, então aqui não há build.
set -euo pipefail
dest="$1"
mkdir -p "$dest"
cp index.html "$dest/"
cp -r assets "$dest/assets"
# arquivos de SEO na raiz (opcionais: só copia se existirem no commit)
for f in robots.txt sitemap.xml llms.txt favicon.ico; do
  [ -f "$f" ] && cp "$f" "$dest/"
done
true
