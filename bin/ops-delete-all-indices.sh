#!/bin/bash

# Copyright Thales 2025
#
# Deletes all application-related OpenSearch indices for a clean reset.
# WARNING: This is destructive — use with care.

OPENSEARCH_URL="https://localhost:9200"
AUTH="admin:Azerty123_"

# Define app-related index name patterns (exact or prefix-based)
INDEX_PATTERNS=(
  "document-index"
  "catalog-index"
  "prompt-index"
  "tag-index"
  "feedback-index"
  "history-index"
  "active-sessions-index"
  "chat-interactions-index"
  "agent-index"
  "session-index"
  "metadata-index"
  "vector-index-ada002"
)

echo "⚠️  Deleting the following application indices:"
for pattern in "${INDEX_PATTERNS[@]}"; do
  echo "  - $pattern"
done

for pattern in "${INDEX_PATTERNS[@]}"; do
  echo "🗑️  Deleting index pattern: $pattern"
  curl -s -X DELETE -k -u "$AUTH" "$OPENSEARCH_URL/$pattern" -w "\n✅ Deleted: $pattern\n"
done

echo "🎉 All selected indices deleted."
