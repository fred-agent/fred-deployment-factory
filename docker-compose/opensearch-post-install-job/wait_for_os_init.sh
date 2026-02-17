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

CLUSTER_NAME=app-opensearch
TIMEOUT=120
CURL_CMD="curl -k -s -u $OPENSEARCH_ADMIN:$OPENSEARCH_ADMIN_PASSWORD https://$CLUSTER_NAME:9200/_cluster/health"

cat << EOF

Waiting for OpenSearch initialization

EOF

elapsed_time=0
while output=$($CURL_CMD); [[ -z "$output" || "$output" == *"OpenSearch Security not initialized"* ]]
do
    if [ $elapsed_time -ge $TIMEOUT ]
    then
        echo "Timeout reached (${TIMEOUT}s): OpenSearch is not ready yet"
        exit 1
    fi
    printf .
    sleep 1
    (( elapsed_time++ ))
done

echo "OpenSearch is ready and secured"
