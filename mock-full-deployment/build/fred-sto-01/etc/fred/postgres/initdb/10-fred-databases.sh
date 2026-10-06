#!/bin/bash
# Exécuté une seule fois, à l'initialisation d'un répertoire de données vide.
# Un compte par consommateur, propriétaire de sa seule base.
set -euo pipefail

# psql n'interpole les variables (:'p', :"u") que sur stdin, pas avec -c.
sql() { psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" "$@" >/dev/null; }

create_db() {
    local user=$1 password=$2
    shift 2
    sql -v u="$user" -v p="$password" <<<"CREATE ROLE :\"u\" LOGIN PASSWORD :'p';"
    for db in "$@"; do
        sql -v u="$user" -v d="$db" <<<"CREATE DATABASE :\"d\" OWNER :\"u\";"
        sql -v d="$db" <<<"REVOKE ALL ON DATABASE :\"d\" FROM PUBLIC;"
        echo "[fred-init] base $db (propriétaire $user)"
    done
}

create_db fred "$FRED_DB_PASSWORD" fred
create_db openfga "$OPENFGA_DB_PASSWORD" openfga
create_db temporal "$TEMPORAL_DB_PASSWORD" temporal temporal_visibility

# pgvector : magasin de vecteurs de Knowledge Flow (pas d'OpenSearch dans cette pile).
sql --dbname fred <<<"CREATE EXTENSION IF NOT EXISTS vector;"
echo "[fred-init] extension vector créée dans fred"
