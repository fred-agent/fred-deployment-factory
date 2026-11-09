#!/usr/bin/env bash
# Keep the existing Keycloak identity data independent of either application DB.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
shared_env_file="${DOCKER_SHARED_ENV_FILE:-$repo_dir/docker/.env}"
# Reuse the existing database image on subsequent starts, or the legacy image
# for its first copy. Explicit KEYCLOAK_POSTGRES_IMAGE in .env still wins.
# Failed inspect calls can write a blank stdout line. Capture each candidate
# separately so those lines cannot become part of the fallback image reference.
if ! KEYCLOAK_DEFAULT_POSTGRES_IMAGE="$(docker inspect -f '{{.Config.Image}}' app-keycloak-postgres 2>/dev/null)"; then
    if ! KEYCLOAK_DEFAULT_POSTGRES_IMAGE="$(docker inspect -f '{{.Config.Image}}' app-postgres 2>/dev/null)"; then
        KEYCLOAK_DEFAULT_POSTGRES_IMAGE=pgvector/pgvector:pg15
    fi
fi
export KEYCLOAK_DEFAULT_POSTGRES_IMAGE

compose() {
    local project="$1"
    shift
    DOCKER_CONTAINER_PREFIX= DOCKER_NETWORK_NAME=fred-shared-network \
        docker compose --env-file "$shared_env_file" \
        -f "$repo_dir/docker/docker-compose-$project.yml" -p "$project" "$@"
}

target_has_realm() {
    docker exec app-keycloak-postgres sh -ec \
        'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc "SELECT to_regclass('\''public.realm'\'') IS NOT NULL"'
}

archive=""
restart_legacy_keycloak=false
cleanup() {
    local result=$?
    if [[ -n "$archive" ]]; then rm -f "$archive"; fi
    if (( result != 0 )) && [[ "$restart_legacy_keycloak" == true ]]; then
        docker start app-keycloak >/dev/null || true
    fi
}
trap cleanup EXIT

compose keycloak up -d --wait keycloak-postgres
bootstrap_needed=false
target_initialized="$(target_has_realm)"
if [[ "$target_initialized" != t ]]; then
    bootstrap_needed=true
    # A legacy Swift volume may contain the existing realm. Copy it once; never
    # drop or modify its database, or restore over an initialized shared realm.
    if docker volume inspect postgres_vol-postgres-data >/dev/null 2>&1; then
        if [[ "$(docker inspect -f '{{.State.Running}}' app-postgres 2>/dev/null || true)" != true ]]; then
            if [[ "$(docker inspect -f '{{.State.Running}}' weaver-app-postgres 2>/dev/null || true)" == true ]]; then
                docker stop weaver-app-postgres >/dev/null
            fi
            if docker container inspect app-postgres >/dev/null 2>&1; then
                compose postgres start --wait postgres
            else
                compose postgres up -d --wait postgres
            fi
        fi
        source_database="$(compose keycloak config --format json \
            | jq -r '.services.keycloak.environment.KC_DB_URL | split("/")[-1]')"
        source_databases="$(docker exec app-postgres sh -ec \
            'psql -U "$POSTGRES_USER" -d postgres -Atc "SELECT datname FROM pg_database"')"
        source_has_realm=f
        if grep -Fxq "$source_database" <<< "$source_databases"; then
            source_has_realm="$(docker exec app-postgres sh -ec \
                'psql -U "$POSTGRES_USER" -d "$1" -Atc "SELECT to_regclass('\''public.realm'\'') IS NOT NULL"' \
                sh "$source_database")"
        fi
        if [[ "$source_has_realm" == t ]]; then
            source_major="$(docker exec app-postgres postgres --version | awk '{print $3}' | cut -d. -f1)"
            target_major="$(docker exec app-keycloak-postgres postgres --version | awk '{print $3}' | cut -d. -f1)"
            if (( source_major > target_major )); then
                echo "Keycloak's source PostgreSQL is newer than its initialized destination. Prepare a compatible destination (KEYCLOAK_POSTGRES_IMAGE and its data volume) before retrying; the source database is unchanged." >&2
                exit 1
            fi
            if [[ "$(docker inspect -f '{{.State.Running}}' app-keycloak 2>/dev/null || true)" == true ]]; then
                docker stop app-keycloak >/dev/null
                restart_legacy_keycloak=true
            fi
            archive="$(mktemp)"
            echo "Copying the existing Keycloak database into its dedicated shared volume..."
            docker exec app-postgres sh -ec \
                'exec pg_dump -U "$POSTGRES_USER" -d "$1" --format=custom --no-owner --no-privileges' \
                sh "$source_database" > "$archive"
            docker exec -i app-keycloak-postgres sh -ec \
                'exec pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --no-privileges --single-transaction' \
                < "$archive"
            bootstrap_needed=false
        fi
    fi
fi

compose keycloak up -d --wait keycloak
if [[ "$bootstrap_needed" == true ]]; then
    ENV_FILE="$shared_env_file" KEYCLOAK_CONTAINER=app-keycloak \
        KEYCLOAK_SERVER_URL=http://localhost:8080 \
        bash "$repo_dir/docker/keycloak/keycloak-post-install.sh"
fi
