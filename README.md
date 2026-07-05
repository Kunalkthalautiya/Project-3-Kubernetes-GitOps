# Project 3 — Kubernetes + GitOps (Industry-Style)

A Kubernetes deployment pipeline modeled on how real teams run GitOps: Helm for packaging,
GitHub Actions for CI, GHCR as the image registry, Sealed Secrets for encrypted credentials
in git, and ArgoCD continuously reconciling the cluster to match this repo.

## Architecture

```
Developer pushes to app/
        |
        v
GitHub Actions:  test -> build image -> push to GHCR -> scan (Trivy) -> bump image tag in values.yaml (commit-back)
        |
        v
Git repo (charts/gitops-demo) is now the source of truth
        |
        v
ArgoCD watches the repo -> auto-syncs -> Kubernetes cluster (minikube)
```

No one runs `kubectl apply` or `docker push` by hand — the pipeline and ArgoCD do it.

## Stack

| Concern            | Tool                              |
|---------------------|------------------------------------|
| Cluster             | minikube (local)                   |
| Packaging           | Helm chart                         |
| CI                  | GitHub Actions                     |
| Image registry      | GHCR (ghcr.io), private            |
| Vulnerability scan  | Trivy (report-only in this demo)   |
| GitOps sync         | ArgoCD                             |
| Secrets in git      | Sealed Secrets (Bitnami)           |
| Autoscaling         | HPA (CPU-based)                    |
| Availability        | PodDisruptionBudget                |

## Repo structure

```
app/                      Flask app, Dockerfile, pytest tests
charts/gitops-demo/       Helm chart — deployment, service, HPA, PDB, sealed secret
argocd/application.yaml   ArgoCD Application CR (cluster-side, not synced by ArgoCD itself)
.github/workflows/ci.yml  CI/CD pipeline
```

## CI/CD flow (`.github/workflows/ci.yml`)

1. **test** — runs `pytest` against the Flask app
2. **build-and-push** — builds the Docker image, tags it with the short commit SHA, pushes to
   `ghcr.io/kunalkthalautiya/gitops-demo-app`, then scans it with Trivy for CRITICAL/HIGH CVEs
3. **update-manifest** — bumps `charts/gitops-demo/values.yaml`'s `image.tag` to the new SHA and
   commits it back to `main` (GitOps commit-back pattern). This only touches `charts/`, which is
   outside the workflow's trigger paths, so it doesn't retrigger itself.

ArgoCD picks up that commit and rolls the new image out automatically.

## Secrets handling

Real credentials are never committed in plaintext. `charts/gitops-demo/templates/sealedsecret.yaml`
holds a `SealedSecret` — data encrypted with the in-cluster Sealed Secrets controller's public key.
Only that controller (running in the target cluster) can decrypt it back into a real `Secret`
that the app consumes via `envFrom`. Losing control of this git repo does not leak the secret.

## Registry & pull access

The GHCR package is private (matches the private repo). The cluster needs an
`imagePullSecret` (`ghcr-pull-secret` in the `gitops-demo` namespace) to pull it — created
out-of-band with `kubectl create secret docker-registry`, not stored in git.

## Local setup

```bash
minikube start --driver=docker

# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --server-side --force-conflicts

# Sealed Secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.27.1/controller.yaml

# Register this (private) repo with ArgoCD — see argocd/application.yaml for the repo Secret format
kubectl apply -f argocd/application.yaml

# Image pull secret for the private GHCR package
kubectl create secret docker-registry ghcr-pull-secret -n gitops-demo \
  --docker-server=ghcr.io --docker-username=<gh-username> --docker-password=<gh-token-with-read:packages>
```

## Next steps

- Move the cluster itself from minikube to EKS, reusing the Terraform modules from Project 2.
- Replace the commit-back tag bump with **Argo CD Image Updater** for a fully native GitOps flow (no bot commits).
- Add a staging environment via a second ArgoCD `Application` + Helm values overlay (`values-staging.yaml`).
