#!/usr/bin/env bash
# Livre build/<vm>/ dans la VM (équivalent d'une copie scp + tar par l'exploitant),
# puis applique les modes et propriétaires listés dans build/<vm>/.perms.
# Usage : scripts/deliver.sh fred-sto-01|fred-app-01
set -euo pipefail
cd "$(dirname "$0")/.."

vm=${1:?usage: deliver.sh <vm>}
src=build/$vm
[[ -f $src/.perms ]] || { echo "ERREUR : $src absent, lancer d'abord 'make render'" >&2; exit 1; }

tar -C "$src" --owner=0 --group=0 --exclude=./.perms -cf - . \
    | docker exec -i "$vm" tar -x --no-overwrite-dir -C /

# Un chemin absent de l'archive est un répertoire de données à créer (/var/lib/fred/...).
docker exec -i "$vm" bash -euo pipefail -c '
while read -r mode owner path; do
    [[ -e $path ]] || mkdir -p "$path"
    chown "$owner" "$path"
    chmod "$mode" "$path"
done' <"$src/.perms"

echo "Livré : $vm"
