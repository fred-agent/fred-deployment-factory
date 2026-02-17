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
INDEX_LIST="$@"

cd $(dirname $0)

for idx in $INDEX_LIST
do
    curl_cmd="curl -v -k -f -s -u $OPENSEARCH_ADMIN:$OPENSEARCH_ADMIN_PASSWORD https://$CLUSTER_NAME:9200/$idx"
    echo "Create indice $idx"
    $curl_cmd || $curl_cmd -X PUT -H "Content-Type: application/json" -d @mapping.json
done
