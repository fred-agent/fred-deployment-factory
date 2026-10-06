#!/usr/bin/env bash
# Jobs one-shot de fred-app-01 (schémas, migrations), dans l'ordre, avant la pile.
# Appelé par fred-deploy.sh. Chaque job est idempotent : relancer ne change rien.
#
# Pourquoi pas depends_on : podman-compose traduit depends_on en "podman --requires",
# qui exige que toute la chaîne requise tourne. Un job terminé y bloque ensuite le
# démarrage des services qui en dépendent, même indirectement ("container state
# improper"). Les jobs sont donc dans le profil "jobs", hors du graphe.
#
# Les images n'ont pas de shell : les arguments des outils Temporal sont passés ici.
set -euo pipefail

COMPOSE=(podman compose -f /opt/fred/compose.yaml)
job() { echo "== job $*"; "${COMPOSE[@]}" --profile jobs run --rm --no-deps -T "$@"; }
SCHEMA=/etc/temporal/schema/postgresql/v12

job temporal-sql --database temporal setup-schema -v 0.0
job temporal-sql --database temporal update-schema -d "$SCHEMA/temporal/versioned"
job temporal-sql --database temporal_visibility setup-schema -v 0.0
job temporal-sql --database temporal_visibility update-schema -d "$SCHEMA/visibility/versioned"
job openfga-migrate
"${COMPOSE[@]}" up -d temporal openfga
podman wait --condition=healthy temporal openfga
job temporal-cli operator namespace describe --namespace default >/dev/null 2>&1 \
    || job temporal-cli operator namespace create --namespace default
# control-plane possède les tables que knowledge-flow lit au démarrage.
job control-plane-migrate
job knowledge-flow-migrate
job fred-agents-migrate
