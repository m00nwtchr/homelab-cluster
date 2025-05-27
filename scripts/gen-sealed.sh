#!/usr/bin/env bash
set -euo pipefail

# Usage check
if [ "$#" -ne 3 ]; then
  cat <<EOF
Usage: $0 <username> <password> <db_host> <db_port> <db_name>

Example:
  $0 alice s3cr3t db.example.com 5432 mydatabase
EOF
  exit 1
fi

USERNAME="$1"
PASSWORD="$(pwgen 64 -n 1 -C -s)"
DB_HOST="postgres-rw.postgres.svc.cluster.local"
DB_PORT="5432"
DB_NAME="$2"
NAMESPACE="$3"

# Construct the full database URL
DATABASE_URL="postgresql://${USERNAME}:${PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

# Seal the credentials secret
echo "# --- Sealed Secret: credentials ---"
kubectl create secret generic "postgres-${USERNAME}" \
  --dry-run=client \
  --namespace="postgres" \
  --from-literal=username="${USERNAME}" \
  --from-literal=password="${PASSWORD}" \
  -o json | \
kubeseal --format yaml

# Separator (optional)
echo

# Seal the db-url secret
echo "# --- Sealed Secret: db-url ---"
kubectl create secret generic "${USERNAME}-env" \
  --dry-run=client \
  --namespace="$NAMESPACE" \
  --from-literal=database_url="${DATABASE_URL}" \
  -o json | \
kubeseal --format yaml
