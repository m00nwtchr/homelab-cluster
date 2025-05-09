#!/usr/bin/env bash

set -euo pipefail

# Path to your cluster's public cert, or let kubeseal use the controller from the cluster
# PUB_CERT=--cert my-sealed-secrets-cert.pem
PUB_CERT=""

echo "Fetching annotated secrets..."

kubectl get secrets --all-namespaces \
	--field-selector type!=kubernetes.io/service-account-token \
	-o json \
| jq -r '
	.items[]
	| select(.metadata.annotations["sealedsecrets.bitnami.com/managed"] == "true")
	| "\(.metadata.namespace) \(.metadata.name)"
' | while read -r namespace secret; do
	echo "Sealing secret: $namespace/$secret"

	# Dump the original secret as YAML
	kubectl get secret "$secret" -n "$namespace" -o yaml | kubeseal $PUB_CERT -o yaml > "${namespace}-${secret}.sealed.yaml"
done

echo "All done."

