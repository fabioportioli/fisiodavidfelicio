#!/usr/bin/env bash
# Monta em $1 só o que o servidor precisa. Roda na raiz do projeto (pasta atual).
# Site de página única com CSS e JS embutidos no index.html, então aqui não há build.
set -euo pipefail
dest="$1"
mkdir -p "$dest"
cp index.html "$dest/"
cp -r assets "$dest/assets"
