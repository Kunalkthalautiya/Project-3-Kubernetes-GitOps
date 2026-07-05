# Project 3 — Kubernetes + GitOps (ArgoCD)

Local Kubernetes deployment demo using GitOps principles — instead of `kubectl apply`,
ArgoCD watches this Git repository and automatically syncs the cluster state to match
what's committed in the `k8s/` folder.

## Architecture

```
Git repo (k8s/ manifests) --> ArgoCD (watches repo) --> Kubernetes cluster (minikube)
```

Change a manifest, commit it, and ArgoCD auto-syncs the cluster — no manual `kubectl apply`.

## Stack

| Component  | Tool                     |
|------------|--------------------------|
| Cluster    | minikube                 |
| App        | Flask (Python)           |
| GitOps     | ArgoCD                   |
| Container  | Docker                   |

## Structure

```
app/         Flask app + Dockerfile
k8s/         Kubernetes manifests (namespace, deployment, service) — the GitOps source of truth
argocd/      ArgoCD Application definition
```

## Local Setup

1. Start the cluster: `minikube start`
2. Build the app image directly into minikube's Docker daemon:
   ```
   eval $(minikube docker-env)
   docker build -t gitops-demo-app:v1 ./app
   ```
3. Install ArgoCD: `kubectl create namespace argocd && kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml`
4. Apply the ArgoCD `Application` resource (`argocd/application.yaml`) so ArgoCD starts watching this repo's `k8s/` folder.
5. Access the ArgoCD UI: `kubectl port-forward svc/argocd-server -n argocd 8080:443`

## Next Steps (future iteration)

- Push this repo to GitHub and point `argocd/application.yaml`'s `repoURL` at it — real GitOps over a remote repo instead of a local one.
- Add a CI step (GitHub Actions) that builds/pushes the image and bumps the image tag in `k8s/deployment.yaml`, letting ArgoCD auto-deploy every merge.
- Move from minikube to EKS (Terraform, reusing patterns from Project 2) for a production-grade cluster.
