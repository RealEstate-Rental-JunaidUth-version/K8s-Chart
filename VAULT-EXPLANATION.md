# Vault + External Secrets in this Kubernetes chart

This document explains how the Vault system works in this project, what each component does, how the secret flow is wired, and what every relevant file is responsible for.

## 1. Big picture

The architecture is:

1. HashiCorp Vault runs as a Kubernetes pod in the `prod` namespace.
2. Vault is initialized and unsealed once.
3. Vault stores secrets in a KV v2 engine mounted at `secret`.
4. The External Secrets Operator (ESO) runs in the cluster.
5. ESO reads secrets from Vault through a `SecretStore` object.
6. ESO creates regular Kubernetes `Secret` objects using `ExternalSecret` objects.
7. Application pods read those Kubernetes secrets via `envFromSecret` or mounted secret keys.

This means your application code never talks to Vault directly. The application just consumes a normal Kubernetes `Secret`, and ESO keeps it synchronized from Vault.

---

## 2. Why this pattern exists

This is a standard GitOps + Kubernetes secret pattern:

- Vault is the centralized secret manager.
- Kubernetes is the runtime environment for deployments.
- External Secrets bridge the two.
- ArgoCD keeps the Helm chart and the K8s resources declarative.

The benefit is that you do not hardcode secrets in Docker images, YAML manifests, or Git repositories.

---

## 3. Main components

### 3.1 Vault

Vault is the secret store.

In this project, Vault is deployed as the `vault` subchart from the HashiCorp Helm chart.

Relevant runtime characteristics from this setup:

- Namespace: `prod`
- Service name: `realestate-prod-vault`
- DNS: `http://realestate-prod-vault.prod.svc.cluster.local:8200`
- Storage backend: file backend in `/vault/data`
- Type: KV v2 secrets engine mounted at `secret`
- Mode: standalone, not HA
- TLS disabled (`tls_disable = 1`)

Because it uses file storage, Vault is a stateful pod backed by a PVC. It must be initialized and unsealed once after deployment or after a restart.

### 3.2 Vault KV v2 engine

The secrets engine is enabled at:

- `secret/`

Within this mount, the project stores secrets under paths like:

- `secret/realestate/mysql`
- `secret/realestate/app`

This is equivalent to the KV v2 path structure:

- `secret/data/realestate/mysql`
- `secret/data/realestate/app`

When using ESO with a `SecretStore` configured with `path: secret` and `version: v2`, you do not write `secret/data/...` again in the `remoteRef.key`. You write the logical path under the mount, like:

- `realestate/mysql`
- `realestate/app`

### 3.3 External Secrets Operator (ESO)

ESO is a controller that watches `SecretStore` and `ExternalSecret` resources.

It reads secret data from external providers like Vault and creates corresponding Kubernetes `Secret` objects.

In this project, ESO is installed via the `external-secrets` Helm chart dependency in `Chart.yaml`.

### 3.4 SecretStore

`SecretStore` tells ESO how to connect to the Vault instance.

In this project, the relevant resource is:

- `realestate-chart/templates/secretstore.yaml`

It specifies:

- Vault server URL
- Vault mount path (`secret`)
- Vault KV version (`v2`)
- Kubernetes auth method
- role `eso-role`
- service account `default` in namespace `prod`

This is the critical trust relationship between Kubernetes and Vault.

### 3.5 ExternalSecret

`ExternalSecret` is the actual mapping that says:

- “Take this value from Vault at this path and property”
- “Write it into this Kubernetes Secret as this key”

In this project, the key resources are:

- `templates/app-secrets.yaml`
- `templates/db-secret.yaml`

### 3.6 Vault Kubernetes auth

This is how ESO authenticates to Vault without static tokens.

Vault is configured with a Kubernetes auth method mounted at:

- `auth/kubernetes`

The role `eso-role` is bound to:

- service account name: `default`
- namespace: `prod`

That means the ESO pod or the Kubernetes service account it uses is trusted by Vault.

### 3.7 Kubernetes secret consumption by apps

Applications consume secrets via:

- `envFrom:`
- `secretRef: app-secrets`

This is done in the Helm deployment templates and `values-prod.yaml`.

The pod then sees environment variables like:

- `PROD_DB_PASSWORD`
- `SECRET_KEY`
- `OAUTH_CLIENT_SECRET`

This is the runtime secret boundary. The application never pulls Vault directly.

---

## 4. Relevant files and what they do

## 4.1 `realestate-chart/Chart.yaml`

This is the Helm chart metadata and dependency list.

It declares the chart dependencies:

- `kafka`
- `vault`
- `external-secrets`
- `cert-manager`
- `ingress-nginx`

This matters because Vault, ESO, cert-manager, and ingress are all deployed as subcharts from the chart.

### What it does

- tells Helm to install the required third-party dependencies
- makes the chart self-contained for the prod cluster

---

## 4.2 `realestate-chart/values-prod.yaml`

This is the main production configuration for the chart.

It contains:

- Vault config (server, file backend, standalone, no dev mode)
- `external-secrets` config
- `cert-manager` config
- `ingress-nginx` config
- service configuration for all microservices
- the `microservices` map with each app
- the `databases` map for database names and storage

### Important parts

#### Vault section

This config enables a real Vault server instead of a dev mode server:

```yaml
vault:
  server:
    dev:
      enabled: false
```

It also configures the storage:

```yaml
storage "file" {
  path = "/vault/data"
}
```

This is why Vault persists data in the pod volume.

#### External Secrets section

```yaml
external-secrets:
  installCRDs: true
```

This ensures the ESO CRDs (`SecretStore`, `ExternalSecret`) are installed in the cluster.

#### Microservice secret wiring

Each service that needs secrets has:

```yaml
envFromSecret: "app-secrets"
```

That tells the deployment template to inject all keys from the `app-secrets` Kubernetes Secret into the container environment.

---

## 4.3 `realestate-chart/templates/secretstore.yaml`

This file defines the `SecretStore` resource.

### Purpose

It tells ESO:

- where Vault lives
- which mount to use
- which authentication method to use
- which Vault role to assume

### Exact behavior

```yaml
provider:
  vault:
    server: "http://realestate-prod-vault.prod.svc.cluster.local:8200"
    path: "secret"
    version: "v2"
    auth:
      kubernetes:
        mountPath: "kubernetes"
        role: "eso-role"
        serviceAccountRef:
          name: "default"
          namespace: "prod"
```

This tells ESO:

- connect to Vault at `realestate-prod-vault.prod.svc.cluster.local:8200`
- use the `secret` KV engine
- use KV v2
- authenticate using the Vault Kubernetes auth backend
- use Vault role `eso-role`

### Why this matters

If the Vault service name, namespace, or auth role is wrong, the `SecretStore` stays `InvalidProviderConfig` and ESO cannot read any secret.

---

## 4.4 `realestate-chart/templates/app-secrets.yaml`

This file defines the application secret mapping.

### Purpose

It creates a Kubernetes Secret named `app-secrets` from Vault values.

### The actual mapping

```yaml
- secretKey: PROD_DB_PASSWORD
  remoteRef:
    key: secret/realestate/mysql
    property: root-password

- secretKey: SECRET_KEY
  remoteRef:
    key: secret/realestate/app
    property: jwt-secret

- secretKey: OAUTH_CLIENT_SECRET
  remoteRef:
    key: secret/realestate/app
    property: oauth-secret
```

### What this means

From Vault:

- `secret/realestate/mysql` -> property `root-password` -> Kubernetes secret key `PROD_DB_PASSWORD`
- `secret/realestate/app` -> property `jwt-secret` -> Kubernetes secret key `SECRET_KEY`
- `secret/realestate/app` -> property `oauth-secret` -> Kubernetes secret key `OAUTH_CLIENT_SECRET`

This secret is then injected into app pods with:

```yaml
envFrom:
  - secretRef:
      name: app-secrets
```

---

## 4.5 `realestate-chart/templates/db-secret.yaml`

This file creates the `mysql-passwords` secret from Vault.

### Purpose

It provides the root password used by MySQL database StatefulSets.

### Mapping

```yaml
- secretKey: mysql-root-password
  remoteRef:
    key: secret/realestate/mysql
    property: root-password
```

This is consumed by StatefulSets such as:

- `property-db`
- `user-db`
- `notification-db`
- `rental-agreement-db`

These DB pods reference the secret by name:

```yaml
env:
  - name: MYSQL_ROOT_PASSWORD
    valueFrom:
      secretKeyRef:
        name: mysql-passwords
        key: mysql-root-password
```

---

## 4.6 `realestate-chart/templates/deployment.yaml`

This is the generic deployment template used for all microservices.

### Purpose

It loops over all entries in `.Values.microservices` and creates `Deployment` resources.

### Important secret integration

```yaml
{{- if $serviceConfig.envFromSecret }}
envFrom:
  - secretRef:
      name: {{ $serviceConfig.envFromSecret }}
{{- end }}
```

This is the part that injects the secret into the running pod.

### Why this matters

If the Secret does not exist yet, Kubernetes fails the pod at container startup with:

- `CreateContainerConfigError`
- `Error: secret "app-secrets" not found`

---

## 4.7 `realestate-chart/init-vault.sh`

This is a helper script for one-time Vault bootstrap.

### What it does

It prints the instructions to:

1. initialize Vault
2. unseal Vault
3. log in with the root token
4. run the configuration script

### It is not meant to run automatically on every deploy.

It is meant for first-time bootstrap / recovery.

---

## 4.8 `realestate-chart/configure-vault.sh`

This is the actual Vault configuration script.

### What it does

It performs the cluster bootstrap required for secret syncing:

1. waits for the Vault pod to be ready
2. enables the KV v2 secrets engine at `secret`
3. writes the app secrets into Vault:
   - `secret/realestate/mysql`
   - `secret/realestate/app`
4. enables Vault Kubernetes auth
5. configures Vault to trust Kubernetes service accounts
6. creates policy `eso`
7. creates role `eso-role`
8. binds the role to the `default` service account in `prod`

### Key part

```bash
vault write auth/kubernetes/role/eso-role \
  bound_service_account_names=default \
  bound_service_account_namespaces=prod \
  policies=eso ttl=24h
```

This is the exact trust relationship that allows ESO to authenticate to Vault.

---

## 9. Safe usage of `configure-vault.sh`

`configure-vault.sh` is a bootstrap script, not the runtime secret-injection mechanism.

Its purpose is to configure Vault itself once the cluster is already running. It is meant to do the setup work, not to be committed with actual secrets inside the repository.

### What the script is responsible for

It does the following:

1. waits for the Vault pod to be ready
2. unseals Vault using a saved key
3. logs in using the root token
4. enables the KV v2 engine at the `secret` mount
5. writes secret data into Vault
6. enables Kubernetes auth in Vault
7. creates the `eso` policy
8. creates the `eso-role` role
9. binds that role to the Kubernetes service account used by ESO

### Why you should not hardcode secrets in the script

This script should not be committed with actual secret values such as:

- `DB_ROOT_PASSWORD`
- `JWT_SECRET`
- `OAUTH_SECRET`
- Vault root token
- Vault unseal key

If those values are placed in a checked-in file, they become part of your Git history and can be exposed to anyone with repo access.

The safe version is:

```bash
: "${VAULT_ROOT_TOKEN:?Set VAULT_ROOT_TOKEN before running this script}"
: "${VAULT_UNSEAL_KEY:?Set VAULT_UNSEAL_KEY before running this script}"
: "${DB_ROOT_PASSWORD:?Set DB_ROOT_PASSWORD before running this script}"
: "${JWT_SECRET:?Set JWT_SECRET before running this script}"
: "${OAUTH_SECRET:?Set OAUTH_SECRET before running this script}"
```

This makes the script read secrets from the local environment instead of embedding them in the repository.

### What you should do in practice

Use the script only in a secure, local, or controlled environment such as:

```bash
export VAULT_ROOT_TOKEN="..."
export VAULT_UNSEAL_KEY="..."
export DB_ROOT_PASSWORD="..."
export JWT_SECRET="..."
export OAUTH_SECRET="..."

bash ./configure-vault.sh
```

Then keep the script itself outside source control or add it to `.gitignore`.

A better approach is to keep the script in Git but store the real values in a local `.env` file or in your CI/CD secret storage:

```bash
cp .env.example .env
# edit .env with your real values
source .env
bash ./configure-vault.sh
```

This keeps the script versioned while preventing real secrets from being committed to Git.

### Why this is the correct pattern

The real secret lifecycle is:

1. secret is created outside Git
2. secret is stored in Vault
3. ESO reads from Vault
4. ESO creates a Kubernetes Secret
5. pods consume the Kubernetes Secret

This keeps Git clean while still allowing the application to run securely.

---

## 5. Exact secret flow

The full secret flow is:

1. Vault pod is initialized and unsealed.
2. `configure-vault.sh` writes secrets to Vault under `secret/realestate/...`.
3. ESO is installed.
4. `SecretStore` points ESO to the Vault pod with Kubernetes auth.
5. `ExternalSecret` resources define mappings.
6. ESO reads Vault data and creates Kubernetes `Secret` objects.
7. Pods use those Kubernetes secrets through `envFromSecret` or secretKeyRef.

### Example

Vault path:

```text
secret/realestate/app
```

with data:

```text
jwt-secret = ...
oauth-secret = ...
```

becomes Kubernetes secret:

```text
app-secrets
```

with values:

```text
SECRET_KEY=...
OAUTH_CLIENT_SECRET=...
```

---

## 6. Why the original issue happened

The original issue was caused by a mismatch between:

- the Vault path layout
- and the ESO path expectations

The broken values used:

```yaml
key: secret/data/realestate/mysql
key: secret/data/realestate/app
```

But with the `SecretStore` configured as:

```yaml
path: "secret"
version: "v2"
```

ESO expected the logical path under the mount, not the raw API path.

So the correct values are:

```yaml
key: secret/realestate/mysql
key: secret/realestate/app
```

or, in a `SecretStore` with the mount already encoded, often effectively represented as:

```yaml
key: realestate/mysql
key: realestate/app
```

This mismatch caused ESO to fail to resolve the secret data, which made the `SecretStore` invalid and the app secrets absent.

---

## 7. Important runtime facts from the live cluster

From the cluster analysis:

- `realestate-prod-vault-0` was `Sealed` and `Initialized=false` initially.
- ESO `SecretStore` had `InvalidProviderConfig` and could not log in to Vault because the server URL was wrong (`vault.vault.svc.cluster.local` did not exist).
- After fixing the endpoint and bootstrap flow, the `SecretStore` became `Ready=True`.
- The `app-secrets` and `mysql-passwords` objects were then created successfully.
- Pods consuming those secrets recovered and became `Running`.

This confirms the architecture is correct once:

- Vault is initialized and unsealed,
- the auth config is valid,
- the external-secret keys match Vault,
- and the service name resolves correctly.

---

## 8. Summary

The Vault system in this project is designed to work like this:

- Vault stores all sensitive values centrally.
- ESO reads them and creates Kubernetes Secrets.
- Application pods consume normal Kubernetes Secrets.
- ArgoCD keeps the chart and the resources in sync.
- `SecretStore` + `ExternalSecret` are the key integration points.

The most important files are:

- `Chart.yaml` — dependencies
- `values-prod.yaml` — chart values and environment
- `templates/secretstore.yaml` — the Vault connection object
- `templates/app-secrets.yaml` — app secrets mapping
- `templates/db-secret.yaml` — DB secret mapping
- `configure-vault.sh` — Vault bootstrap and policy setup
- `init-vault.sh` — manual one-time init instructions
- `templates/deployment.yaml` — secret injection into pods

This is the complete secret pipeline used by the real estate Kubernetes deployment.
