#!/bin/sh
#
# Reference Kea Keycloak/Postgres extractor used for the 2026-07-28 cutover.
# It normalizes every realm group into the flat group shape consumed by the
# Swift reconciliation importer, including groups stored below a parent.
#
# The script contains no credential. KEA_KEYCLOAK_DSN is supplied at runtime.
# The generated JSON is sensitive: it contains usernames, stable Keycloak user
# ids, group names, memberships and platform roles. Keep it private and use an
# approved secure transfer channel.

set -eu

: "${KEA_KEYCLOAK_DSN:?Définir KEA_KEYCLOAK_DSN avec le DSN PostgreSQL Keycloak}"

OUTPUT="${1:-kea-realm-reconciliation.json}"
if [ -e "$OUTPUT" ]; then
    echo "Erreur : $OUTPUT existe déjà. Il ne sera pas écrasé." >&2
    exit 1
fi

umask 077

psql "$KEA_KEYCLOAK_DSN" \
    -X -qAt \
    -v ON_ERROR_STOP=1 \
    > "$OUTPUT" <<'SQL'
WITH target_realm AS (
    SELECT id
    FROM realm
    WHERE name = 'app'
),
realm_groups AS (
    SELECT g.id, g.name
    FROM keycloak_group g
    JOIN target_realm r ON r.id = g.realm_id
),
user_groups AS (
    SELECT
        ugm.user_id,
        jsonb_agg('/' || g.name ORDER BY g.name) AS groups
    FROM user_group_membership ugm
    JOIN realm_groups g ON g.id = ugm.group_id
    GROUP BY ugm.user_id
),
platform_roles AS (
    SELECT kr.id, kr.name
    FROM keycloak_role kr
    JOIN target_realm r ON r.id = kr.realm_id
    WHERE kr.client_role IS NOT TRUE
      AND kr.name IN ('admin', 'editor', 'viewer')

    UNION

    SELECT kr.id, kr.name
    FROM keycloak_role kr
    JOIN client c ON c.id = kr.client
    JOIN target_realm r ON r.id = c.realm_id
    WHERE kr.client_role IS TRUE
      AND c.client_id = 'app'
      AND kr.name IN ('admin', 'editor', 'viewer')
),
effective_user_roles AS (
    SELECT urm.user_id, pr.name
    FROM user_role_mapping urm
    JOIN platform_roles pr ON pr.id = urm.role_id

    UNION

    SELECT ugm.user_id, pr.name
    FROM user_group_membership ugm
    JOIN group_role_mapping grm ON grm.group_id = ugm.group_id
    JOIN platform_roles pr ON pr.id = grm.role_id
),
user_roles AS (
    SELECT
        user_id,
        jsonb_agg(name ORDER BY name) AS realm_roles
    FROM effective_user_roles
    GROUP BY user_id
)
SELECT jsonb_pretty(
    jsonb_build_object(
        'groups',
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', g.id,
                        'name', g.name,
                        'subGroups', '[]'::jsonb
                    )
                    ORDER BY g.name
                )
                FROM realm_groups g
            ),
            '[]'::jsonb
        ),
        'users',
        COALESCE(
            (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'id', u.id,
                        'username', u.username,
                        'groups', COALESCE(ug.groups, '[]'::jsonb),
                        'realmRoles', COALESCE(ur.realm_roles, '[]'::jsonb)
                    )
                    ORDER BY u.username
                )
                FROM user_entity u
                JOIN target_realm r ON r.id = u.realm_id
                LEFT JOIN user_groups ug ON ug.user_id = u.id
                LEFT JOIN user_roles ur ON ur.user_id = u.id
                WHERE u.service_account_client_link IS NULL
            ),
            '[]'::jsonb
        )
    )
);
SQL

test -s "$OUTPUT"
sha256sum "$OUTPUT" > "$OUTPUT.sha256"

echo "Fichier produit : $OUTPUT"
echo "Checksum produit : $OUTPUT.sha256"
wc -c "$OUTPUT"
