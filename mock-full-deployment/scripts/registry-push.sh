#!/usr/bin/env bash
# Pousse dans le registry local les images de images.tsv dont la source est connue.
# Une source peut être fournie ou remplacée en argument, par exemple pour les
# images hardenées :  scripts/registry-push.sh CONTROL_PLANE_IMAGE=mon/image:tag
set -euo pipefail
cd "$(dirname "$0")/.."

declare -A override=()
for arg in "$@"; do override[${arg%%=*}]=${arg#*=}; done

missing=()
while IFS=$'\t' read -r var src target; do
    [[ -z $var || $var == \#* ]] && continue
    src=${override[$var]:-$src}
    if [[ $src == TODO ]]; then
        missing+=("$var")
        continue
    fi
    docker image inspect "$src" >/dev/null 2>&1 || docker pull "$src"
    docker tag "$src" "localhost:5000/$target"
    docker push -q "localhost:5000/$target"
    echo "OK $var  $src -> registry.fred.lan:5000/$target"
done <images.tsv

if ((${#missing[@]})); then
    echo "Sans source (à fournir) : ${missing[*]}"
fi
