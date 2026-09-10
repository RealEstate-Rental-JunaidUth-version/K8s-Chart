#!/bin/bash
set -e

VAULT_POD="${VAULT_POD:-realestate-prod-vault-0}"
VAULT_NS="${VAULT_NS:-prod}"

: "${VAULT_ROOT_TOKEN:?Set VAULT_ROOT_TOKEN before running this script}"
: "${VAULT_UNSEAL_KEY:?Set VAULT_UNSEAL_KEY before running this script}"
: "${DB_ROOT_PASSWORD:?Set DB_ROOT_PASSWORD before running this script}"
: "${JWT_SECRET:?Set JWT_SECRET before running this script}"
: "${OAUTH_SECRET:?Set OAUTH_SECRET before running this script}"

kubectl wait --for=condition=ready pod/$VAULT_POD -n $VAULT_NS --timeout=300s

kubectl exec -n $VAULT_NS $VAULT_POD -- vault operator unseal "$VAULT_UNSEAL_KEY" || true
kubectl exec -n $VAULT_NS $VAULT_POD -- vault login "$VAULT_ROOT_TOKEN"

echo "Enabling KV secrets engine..."
kubectl exec -n $VAULT_NS $VAULT_POD -- vault secrets enable -path=secret kv-v2 || true

echo "Writing secrets to Vault..."
kubectl exec -n $VAULT_NS $VAULT_POD -- vault kv put secret/realestate/mysql root-password="$DB_ROOT_PASSWORD"
kubectl exec -n $VAULT_NS $VAULT_POD -- vault kv put secret/realestate/app jwt-secret="$JWT_SECRET" oauth-secret="$OAUTH_SECRET"

echo "Configuring Vault Kubernetes Auth..."
kubectl exec -n $VAULT_NS $VAULT_POD -- vault auth enable kubernetes || true
kubectl exec -n $VAULT_NS $VAULT_POD -- sh -c 'vault write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc.cluster.local:443" disable_iss_validation=true'

echo "Creating Vault policy for ESO..."
kubectl exec -n $VAULT_NS $VAULT_POD -- sh -c 'cat <<EOF > /tmp/eso-policy.hcl
path "secret/data/realestate/*" {
  capabilities = ["read", "list"]
}
EOF'
kubectl exec -n $VAULT_NS $VAULT_POD -- vault policy write eso /tmp/eso-policy.hcl

echo "Creating Vault Kubernetes Role..."
kubectl exec -n $VAULT_NS $VAULT_POD -- vault write auth/kubernetes/role/eso-role bound_service_account_names=default bound_service_account_namespaces=prod policies=eso ttl=24h

echo "Done! Vault is configured."
