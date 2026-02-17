#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  INDEX="vector-index"
else
  INDEX="$1"
fi


curl -fsSk -u admin:Azerty123_ \
  -X GET "https://localhost:9200/${INDEX}/_search" \
  -H 'Content-Type: application/json' \
  -d '{"size":10}' \
| jq --arg index "$INDEX" '
{
  index: $index,
  total_hits: (.hits.total.value // .hits.total // 0),
  hits: [
    .hits.hits[] | {
      id: ._id,
      score: ._score,
      text: (
        (._source.text // "")
        | gsub("\\s+"; " ")
        | if length > 400 then .[0:400] + "..." else . end
      ),
      metadata: {
        chunk_uid: (._source.metadata.chunk_uid // null),
        file_name: (._source.metadata.file_name // ._source.metadata.document_name // null),
        page: (._source.metadata.page // null),
        session_id: (._source.metadata.session_id // null),
        user_id: (._source.metadata.user_id // null),
        scope: (._source.metadata.scope // null),
        source: (._source.metadata.source // null),
        retrievable: (._source.metadata.retrievable // null)
      }
    }
  ]
}'
