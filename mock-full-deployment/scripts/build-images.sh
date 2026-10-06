#!/usr/bin/env bash
# Construit les images durcies (images/<nom>/Containerfile) sous fred-hardened/<nom>:latest,
# sources de images.tsv. Les images Fred se construisent depuis FRED_REPO (config.env),
# les autres depuis leur répertoire.
# Usage : scripts/build-images.sh [nom...]          (défaut : toutes)
#         REFRESH=1 scripts/build-images.sh ...     (sans cache : derniers correctifs Wolfi)
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source config.env; set +a

fred=(control-plane-backend knowledge-flow-backend fred-agents frontend)
infra=(postgres seaweedfs openfga temporal-server temporal-admin-tools)
(($#)) && names=("$@") || names=("${infra[@]}" "${fred[@]}")

for name in "${names[@]}"; do
    [[ -f images/$name/Containerfile ]] || { echo "ERREUR : images/$name/Containerfile absent" >&2; exit 1; }
    args=(-f "images/$name/Containerfile" -t "fred-hardened/$name:latest")
    [[ ${REFRESH:-} == 1 ]] && args+=(--no-cache)
    ctx=images/$name
    if [[ " ${fred[*]} " == *" $name "* ]]; then
        ctx=$FRED_REPO
        args+=(--label "org.opencontainers.image.revision=$(git -C "$FRED_REPO" rev-parse HEAD)")
    fi
    [[ $name == frontend ]] && args+=(--build-arg "NGINX_CONF=$(cat images/frontend/nginx.conf)")
    echo "== $name"
    docker build -q "${args[@]}" "$ctx"
done
