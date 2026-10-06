#!/usr/bin/env bash
# Contrôles après déploiement : état des conteneurs, chiffrement inter-VM effectif,
# refus du clair, et configuration OIDC servie au navigateur.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source config.env; set +a

ok() { printf '  \e[32mOK\e[0m   %s\n' "$1"; }
ko() { printf '  \e[31mKO\e[0m   %s\n' "$1"; fail=1; }
fail=0

echo "== Conteneurs"
for vm in fred-sto-01 fred-app-01; do
    echo "-- $vm"
    docker exec "$vm" podman ps -a --format '{{.Names}}\t{{.Status}}' | sed 's/^/     /'
done

echo "== Chiffrement fred-app-01 -> fred-sto-01"
# Une connexion TLS vérifiée contre la CA interne (nom du certificat compris).
if docker exec fred-app-01 bash -c "openssl s_client -connect $STO_FQDN:5432 -starttls postgres \
        -verify_return_error -verify_hostname $STO_FQDN -CAfile /etc/fred/tls/ca.crt </dev/null >/dev/null 2>&1"; then
    ok "Postgres 5432 : TLS, certificat valide pour $STO_FQDN"
else ko "Postgres 5432 : TLS vérifié impossible"; fi
if docker exec fred-app-01 bash -c "openssl s_client -connect $STO_FQDN:8333 \
        -verify_return_error -verify_hostname $STO_FQDN -CAfile /etc/fred/tls/ca.crt </dev/null >/dev/null 2>&1"; then
    ok "S3 8333 : HTTPS, certificat valide pour $STO_FQDN"
else ko "S3 8333 : HTTPS vérifié impossible"; fi
# Sessions réellement chiffrées côté serveur (pg_stat_ssl).
docker exec fred-sto-01 podman exec -u postgres postgres psql -U postgres -tAc \
    "select a.usename, a.datname, s.ssl, s.version from pg_stat_ssl s join pg_stat_activity a using (pid) where a.client_addr is not null" \
    | sed 's/^/     /'
plain=$(docker exec fred-sto-01 podman exec -u postgres postgres psql -U postgres -tAc \
    "select count(*) from pg_stat_ssl s join pg_stat_activity a using (pid) where a.client_addr is not null and not s.ssl")
[[ $plain == 0 ]] && ok "aucune session Postgres en clair" || ko "$plain session(s) Postgres en clair"

echo "== Refus du clair"
if docker exec fred-app-01 bash -c "timeout 5 bash -c '</dev/tcp/$STO_FQDN/9333'" 2>/dev/null; then
    ko "port interne SeaweedFS 9333 joignable depuis fred-app-01"
else ok "ports internes SeaweedFS non exposés"; fi
# Un serveur TLS répond 400 à une requête en clair : seul ce code est acceptable.
code=$(docker exec fred-app-01 curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$STO_FQDN:8333/")
[[ $code == 400 || $code == 000 ]] && ok "S3 refuse le HTTP clair ($code)" || ko "S3 répond en HTTP clair ($code)"

echo "== Navigateur"
cfgjson=$(curl -s --max-time 10 "$PUBLIC_URL/control-plane/v1/frontend/config")
if grep -q '"oidc"' <<<"$cfgjson" && grep -q 'login.microsoftonline.com' <<<"$cfgjson"; then
    ok "$PUBLIC_URL sert la configuration OIDC Entra"
else ko "$PUBLIC_URL/control-plane/v1/frontend/config ne renvoie pas la configuration Entra"; fi

exit $fail
