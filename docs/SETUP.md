# Setup Guide

Complete, copy-pasteable commands for setting this project up from scratch — on your own AWS
account, your own fork, with your own credentials. The main [README](../README.md) covers the
"what" and "why"; this doc is the literal "run these commands in this order."

## 0. Prerequisites

| Tool | Check | Install |
|---|---|---|
| `kubectl` | `kubectl version --client` | `brew install kubectl` |
| `helm` | `helm version` | `brew install helm` |
| `minikube` (local path) | `minikube version` | `brew install minikube` |
| `terraform` (EKS path) | `terraform version` | `brew install terraform` |
| `aws` CLI (EKS path) | `aws --version` | `brew install awscli` → `aws configure` |
| `gh` CLI | `gh --version` | `brew install gh` → `gh auth login` |
| `kubeseal` | `kubeseal --version` | `brew install kubeseal` |

**GitHub token scopes** — whatever token you use for `gh auth login` (or a PAT) needs:
- `repo` — for ArgoCD/Image Updater to read/write this (private) repo
- `read:packages` — for the cluster to pull images from your private GHCR package. If you only
  authenticated with `gh auth login` originally without this scope, add it with:
  ```bash
  gh auth refresh -h github.com -s read:packages
  ```

**AWS IAM permissions** (EKS path only) — needs to create VPC, EKS, RDS, IAM roles, S3, DynamoDB,
CloudWatch/SNS resources. `AdministratorAccess` is simplest for a personal/demo account; a scoped
policy for a shared account would need at minimum `AmazonEKSClusterPolicy`-adjacent permissions
plus `rds:*`, `s3:*` (scoped to the state bucket), `dynamodb:*` (scoped to the lock table), and
`cloudwatch:*`/`sns:*`.

## 1. Fork/clone and point it at your own registry

This repo's manifests hardcode `ghcr.io/kunalkthalautiya/...` and
`github.com/Kunalkthalautiya/...`. Fork the repo, then find-and-replace those with your own
GitHub username in:
- `charts/gitops-demo/values.yaml` (`image.repository`)
- `argocd/application.yaml`, `argocd/application-staging.yaml` (`repoURL`, `pull-secret` username)
- `.github/workflows/ci.yml` (image name is derived from `github.repository_owner`, no edit needed)

## 2. Choose a path: minikube (free, local) or EKS (real AWS, costs money)

### 2a. minikube
```bash
minikube start --driver=docker

# build the image straight into minikube's docker daemon (no registry needed for this path)
eval $(minikube docker-env)
docker build -t gitops-demo-app:v1 ./app

# in charts/gitops-demo/values.yaml, set postgres.enabled: true and DB_HOST: postgres
# (there's no RDS to reach from a local cluster)
```

### 2b. EKS
```bash
cd infra/bootstrap && terraform init && terraform apply -auto-approve   # one-time, remote state backend
cd ../eks && terraform init && terraform plan -out=tfplan && terraform apply "tfplan"
aws eks update-kubeconfig --region ap-south-1 --name project3-eks
kubectl get nodes   # confirm Ready

# If a node shows pods stuck Pending due to density limits, scale the node group — see
# docs/eks-migration.md#1-tsmall-pod-density-limit
```

## 3. Install the cluster-side controllers (both paths)

```bash
# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side --force-conflicts
kubectl wait --for=condition=available --timeout=180s deployment/argocd-server -n argocd

# Sealed Secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/controller.yaml

# Argo CD Image Updater
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/v1.2.2/config/install.yaml
```

## 4. Register your GitHub repo with ArgoCD

Not stored anywhere in this repo (it holds a real token) — create it directly:
```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: project-3-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/<your-username>/Project-3-Kubernetes-GitOps
  username: <your-username>
  password: $(gh auth token)
EOF
```

## 5. Per-namespace secrets (repeat for each namespace: `gitops-demo`, `gitops-demo-staging`, ...)

```bash
NAMESPACE=gitops-demo   # or gitops-demo-staging, etc.

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Image pull secret — needed because the GHCR package is private
kubectl create secret docker-registry ghcr-pull-secret -n "$NAMESPACE" \
  --docker-server=ghcr.io \
  --docker-username=<your-github-username> \
  --docker-password="$(gh auth token)" \
  --docker-email=<your-email>

# Sealed secret with real app + DB credentials — see step 6, it's namespace-specific
```

## 6. Create a SealedSecret for a namespace

Sealed Secrets encryption is bound to a specific namespace (see
[troubleshooting.md #12](troubleshooting.md)), so this has to be repeated per namespace/environment:

```bash
NAMESPACE=gitops-demo
SECRET_NAME=gitops-demo-secret

# Fetch this cluster's public cert (EKS: needs a port-forward, pods aren't locally routable)
kubectl port-forward -n kube-system svc/sealed-secrets-controller 8081:8080 &
sleep 2
curl -s http://localhost:8081/v1/cert.pem -o /tmp/pubcert.pem

# Build the plaintext secret (never applied directly, only sealed)
kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-literal=DEMO_API_KEY=<any-value> \
  --from-literal=POSTGRES_USER=<db-username> \
  --from-literal=POSTGRES_PASSWORD=<db-password> \
  --from-literal=POSTGRES_DB=<db-name> \
  --dry-run=client -o yaml > /tmp/plain-secret.yaml

kubeseal --format=yaml --cert=/tmp/pubcert.pem \
  < /tmp/plain-secret.yaml > charts/gitops-demo/templates/sealedsecret.yaml   # or sealedsecret-staging.yaml, etc.

rm -f /tmp/pubcert.pem /tmp/plain-secret.yaml
kill %1   # stop the port-forward
```
Commit the resulting `sealedsecret*.yaml` — it's encrypted, safe to push.

## 7. Apply the ArgoCD Applications

```bash
kubectl apply -f argocd/application.yaml            # prod -> gitops-demo namespace
kubectl apply -f argocd/application-staging.yaml    # staging -> gitops-demo-staging namespace (optional)
```
Give it a minute; if `status.sync.status` stays stuck on a stale revision, force it:
```bash
kubectl patch application gitops-demo-app -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'
```

## 8. Verify

```bash
kubectl get pods -n gitops-demo
kubectl port-forward svc/gitops-demo -n gitops-demo 8000:80 &
curl http://localhost:8000/api/visits   # should return an incrementing counter
```

## Adding another environment (e.g. a third "qa" tier)

This generalizes what `values-staging.yaml` / `application-staging.yaml` already do for staging:

1. Create `charts/gitops-demo/values-qa.yaml` — copy `values-staging.yaml`, adjust
   `environment: qa`, `replicaCount`, `POSTGRES_DB` (pick a new logical DB name), `APP_VERSION`.
2. If using a shared RDS instance, create that logical database once (see
   [eks-migration.md #6](eks-migration.md#6-rds-is-in-a-private-subnet--no-direct-psql-from-a-laptop)
   for the "no direct psql" workaround):
   ```bash
   kubectl run psql-tmp --image=postgres:16-alpine --rm -i --restart=Never \
     --env="PGPASSWORD=$DB_PASS" -- \
     psql -h "$RDS_HOST" -U <user> -d <existing-db> -c "CREATE DATABASE qa_db_name;"
   ```
3. Add a new guarded template `charts/gitops-demo/templates/sealedsecret-qa.yaml`
   (`{{- if eq .Values.environment "qa" }}`), sealed per step 6 above for the `qa` namespace.
4. Copy `argocd/application-staging.yaml` → `argocd/application-qa.yaml`: change `metadata.name`,
   `destination.namespace`, the `valueFiles` list, and the Image Updater
   `pull-secret`/`write-back-target` annotations to point at the new namespace/values file.
5. Repeat steps 5 (namespace + secrets) and 7 (apply) above for `qa`.
