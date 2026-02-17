# Copyright Thales 2025
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#!/usr/bin/env bash

[ ! -d /usr/local/etc/opensearch-security/ ] && mkdir -p /usr/local/etc/opensearch-security/
[ ! -d /usr/local/etc/opensearch-dashboards/ ] && mkdir -p /usr/local/etc/opensearch-dashboards/

# # OpenSearch - opensearch.yml
# cp /tmp/opensearch-config/opensearch.yml /usr/share/opensearch/config/opensearch.yml

# OpenSearch - internal_users.yml
OPENSEARCH_ADMIN_PASSWORD_HASH=$(htpasswd -nbB $OPENSEARCH_ADMIN $OPENSEARCH_ADMIN_PASSWORD | awk -F: '{ print $NF}')
sed "s#__OPENSEARCH_ADMIN__#$OPENSEARCH_ADMIN#;
    s#__OPENSEARCH_ADMIN_PASSWORD_HASH__#$OPENSEARCH_ADMIN_PASSWORD_HASH#" /tmp/opensearch-config/internal_users.yml \
    > /usr/local/etc/opensearch-security/internal_users.yml

# OpenSearch - roles_mapping.yml
cp /tmp/opensearch-config/roles_mapping.yml /usr/local/etc/opensearch-security/roles_mapping.yml

# OpenSearch - roles.yml
cp /tmp/opensearch-config/roles.yml /usr/local/etc/opensearch-security/roles.yml

# OpenSearch - config.yml
sed "s#__KEYCLOAK_HOST__#$KEYCLOAK_HOST#" /tmp/opensearch-config/config.yml \
    > /usr/local/etc/opensearch-security/config.yml

# OpenSearch Dashboards - opensearch_dashboards.yml
sed "s#__KEYCLOAK_HOST__#$KEYCLOAK_HOST#;
    s#__OPENSEARCH_ADMIN__#$OPENSEARCH_ADMIN#;
    s#__OPENSEARCH_ADMIN_PASSWORD__#$OPENSEARCH_ADMIN_PASSWORD#;
    s#__DOCKER_COMPOSE_HOST_FQDN__#$DOCKER_COMPOSE_HOST_FQDN#" /tmp/opensearch-dashboards-config/opensearch_dashboards.yml \
    > /usr/local/etc/opensearch-dashboards/opensearch_dashboards.yml

# User:group is 1000:1000 in OpenSearch docker images
chown -R 1000:1000 /usr/local/etc