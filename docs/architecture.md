# Architecture

## What this project is

A Flask app + Postgres database, deployed to Kubernetes entirely through GitOps: nobody runs
`kubectl apply` or `docker push` by hand. A commit to `main` is the only action a human takes;
everything from there — build, scan, deploy, reconcile — is automated.

## End-to-end flow

```
 Developer                GitHub Actions CI              Git repo               ArgoCD                 Kubernetes
 ─────────                ─────────────────              ────────               ──────                 ──────────
 push to app/  ────────►  test (pytest)
                          build image
                          push to GHCR (private)
                          scan image (Trivy)
                          bump image.tag in
                          values.yaml, commit back ────►  charts/gitops-demo/
                                                           values.yaml updated
                                                                                  ◄── polls repo
                                                                                  detects new commit
                                                                                  renders Helm chart
                                                                                  applies diff        ────►  Deployment rolls
                                                                                                              out new image
```

## Components

### App tier
- Flask app (`app/app.py`), 2 replicas (`Deployment`), fronted by a `Service`.
- `GET /` — static hello message.
- `GET /healthz` — liveness/readiness target, doesn't touch the database (so DB slowness never
  fails the app's own health checks).
- `GET /api/visits` — inserts a row into Postgres and returns the row count. This is the proof
  that the app persists real state rather than being stateless/mocked.
- Scales via `HorizontalPodAutoscaler` (CPU-based, 2–5 replicas) and stays available during
  voluntary disruptions via a `PodDisruptionBudget` (`minAvailable: 1`).

### Data tier
- Postgres runs as a `StatefulSet` (stable pod identity: `postgres-0`) with a
  `PersistentVolumeClaim` per pod via `volumeClaimTemplates`.
- A headless `Service` (`clusterIP: None`) gives it stable DNS
  (`postgres.gitops-demo.svc.cluster.local`); the app connects via `DB_HOST=postgres`.
- Storage class differs by cluster: `standard` on minikube (hostpath-backed), `gp2` on EKS
  (EBS-backed). See [troubleshooting.md](troubleshooting.md) for why this isn't portable as-is.

### CI/CD (`.github/workflows/ci.yml`)
1. **test** — `pytest` against the Flask app.
2. **build-and-push** — builds the Docker image, tags with the short commit SHA, pushes to
   `ghcr.io/kunalkthalautiya/gitops-demo-app`, scans it with Trivy (report-only: `exit-code: 0`).
3. **update-manifest** — bumps `charts/gitops-demo/values.yaml`'s `image.tag` and commits it back
   to `main`. This only touches `charts/`, which is outside the workflow's trigger `paths`, so the
   bot's own commit doesn't retrigger the pipeline — no infinite loop, no need for an actor check.

### GitOps sync (ArgoCD)
- One `Application` resource (`argocd/application.yaml`, applied directly to the cluster — it is
  not itself synced by ArgoCD) points at `charts/gitops-demo` in this GitHub repo.
- `syncPolicy.automated` with `prune: true` and `selfHeal: true`: any drift between the repo and
  the live cluster gets corrected automatically, in both directions (new commits roll out; manual
  `kubectl edit` on a live resource gets reverted).
- Private repo access requires a `Secret` in the `argocd` namespace labeled
  `argocd.argoproj.io/secret-type: repository`, holding a GitHub token with `repo` scope.

### Secrets
- `charts/gitops-demo/templates/sealedsecret.yaml` is a `SealedSecret` (Bitnami Sealed Secrets),
  holding `DEMO_API_KEY` and the real Postgres credentials
  (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`).
- Encryption is with the in-cluster Sealed Secrets controller's public key. Only that specific
  controller (i.e., that specific cluster) can decrypt it. This means the committed
  `sealedsecret.yaml` is cluster-specific — see [troubleshooting.md](troubleshooting.md).
- Both the app `Deployment` and the Postgres `StatefulSet` consume the decrypted `Secret` via
  `envFrom`.

### Registry access
- GHCR package is private (mirrors the private repo). Pulling it requires an `imagePullSecret`
  (`ghcr-pull-secret` in the `gitops-demo` namespace) — created out-of-band with
  `kubectl create secret docker-registry`, never committed to git.

## Two cluster targets

| | minikube | AWS EKS (`infra/eks/`) |
|---|---|---|
| Purpose | local dev/demo, free | "real cloud" verification |
| Provisioning | `minikube start` | Terraform (`terraform-aws-modules/vpc` + `.../eks`) |
| Storage class | `standard` (hostpath) | `gp2` (EBS, via `aws-ebs-csi-driver` addon) |
| Cost | free | ~$120/month if left running |
| Sealed Secret | encrypted for minikube's controller key | re-sealed for EKS's controller key |

Full EKS setup/teardown steps: [eks-migration.md](eks-migration.md).
