# Architecture

## What this project is

A Flask app + RDS Postgres database, deployed to two environments (prod, staging) on Kubernetes
entirely through GitOps: nobody runs `kubectl apply`, `docker push`, or bumps an image tag by
hand. A commit to `main` is the only action a human takes; everything from there — build, scan,
tag rollout, deploy, reconcile — is automated.

## End-to-end flow

```
 Developer          GitHub Actions CI         Argo CD Image Updater      Git repo            ArgoCD (x2)          Kubernetes
 ─────────          ─────────────────         ──────────────────────     ────────            ───────────          ──────────
 push to app/ ────► test (pytest)
                    build image
                    push to GHCR (private)
                    scan image (Trivy)
                                        ─────► polls GHCR for new
                                               commit-SHA tags
                                               writes new tag to  ────►  values.yaml (prod)
                                               values*.yaml itself       values-staging.yaml
                                                                                              ◄── polls repo per Application
                                                                                              renders Helm chart
                                                                                              applies diff          ────► Deployment rolls
                                                                                                                           out new image
```

CI's job ends the moment the image lands in the registry. It never touches git — Image Updater
owns the write-back step, per `Application`, via annotations (no shared "bump" job to coordinate).

## Components

### App tier
- Flask app (`app/app.py`): `Deployment` — 2 replicas in prod, 1 in staging (`values-staging.yaml`).
- `GET /` — static hello message, includes `APP_VERSION` (`"v1"` prod, `"staging"` staging).
- `GET /healthz` — liveness/readiness target, doesn't touch the database (so DB slowness never
  fails the app's own health checks).
- `GET /api/visits` — inserts a row into Postgres and returns the row count. Proof the app
  persists real state rather than being stateless/mocked, and that prod/staging are genuinely
  isolated (each keeps its own count).
- Scales via `HorizontalPodAutoscaler` (CPU-based) and stays available during voluntary
  disruptions via a `PodDisruptionBudget` (prod only — not worth it at staging's 1 replica).

### Data tier — RDS PostgreSQL
- A single managed `db.t3.micro` RDS instance (`infra/eks/main.tf`), **not** a database running
  in the cluster.
- Prod and staging share the instance but use separate logical databases (`gitopsdemo` vs
  `gitopsdemo_staging`) — isolated data, one bill.
- An in-cluster Postgres `StatefulSet` still exists in the chart (`postgres.enabled: false` by
  default) so the same chart works standalone on minikube, where there's no RDS to reach.
- AWS handles backups/patching for RDS; the in-cluster path (when used) has none of that —
  see [troubleshooting.md](troubleshooting.md) for the bugs hit running Postgres in-cluster
  before this migration.

### CI/CD (`.github/workflows/ci.yml`)
1. **test** — `pytest` against the Flask app.
2. **build-and-push** — builds the Docker image, tags with the short commit SHA, pushes to
   `ghcr.io/kunalkthalautiya/gitops-demo-app`, scans it with Trivy (report-only: `exit-code: 0`).

No third job. The old "bump image tag and commit" step is gone — Image Updater replaced it.

### Image rollout (Argo CD Image Updater)
- Configured per-`Application` via annotations (`argocd-image-updater.argoproj.io/*`), not in CI.
- `update-strategy: latest` + `allow-tags: regexp:^[0-9a-f]{7}$` — picks the most recently pushed
  tag matching the commit-SHA pattern (ignores the mutable `:latest` tag CI also pushes).
- `write-back-method: git` — commits the new tag directly into the relevant values file
  (`values.yaml` for prod, `values-staging.yaml` for staging via `write-back-target`).
- Registry auth for a private GHCR package: `pull-secret: pullsecret:<namespace>/ghcr-pull-secret`.

### GitOps sync (ArgoCD) — two Applications, one chart
- `argocd/application.yaml` → `gitops-demo` namespace (prod), `argocd/application-staging.yaml` →
  `gitops-demo-staging` namespace, both applied directly to the cluster (not themselves synced by
  ArgoCD — they're the entry point, not something ArgoCD manages recursively).
- Both point at `charts/gitops-demo`; staging additionally layers `values-staging.yaml`.
- `syncPolicy.automated` with `prune: true` and `selfHeal: true` on both: drift between repo and
  live cluster is corrected automatically, in both directions.
- Private repo access requires a `Secret` in the `argocd` namespace labeled
  `argocd.argoproj.io/secret-type: repository`, holding a GitHub token with `repo` scope — shared
  by both Applications since it's registered once per repo, not per Application.

### Secrets — one per environment
- `templates/sealedsecret.yaml` (namespace `gitops-demo`) and `templates/sealedsecret-staging.yaml`
  (namespace `gitops-demo-staging`) are separate `SealedSecret` resources, each gated by
  `{{- if eq .Values.environment "..." }}` so only the one matching the active values file renders.
- Sealed Secrets encryption is bound to a specific **namespace** (not just cluster), so a secret
  sealed for `gitops-demo` cannot decrypt in `gitops-demo-staging` even on the same cluster —
  hence two separate sealed files, not one reused across namespaces.
- Both hold `DEMO_API_KEY` and real Postgres credentials (`POSTGRES_USER`, `POSTGRES_PASSWORD`,
  `POSTGRES_DB` — differing only in `POSTGRES_DB` between environments), consumed via `envFrom`.

### Registry access
- GHCR package is private. Each namespace needs its own `imagePullSecret` (`ghcr-pull-secret`) —
  created out-of-band with `kubectl create secret docker-registry`, never committed to git.

### Terraform state (`infra/bootstrap/`)
- S3 bucket (versioned, SSE-encrypted, public access blocked) + DynamoDB lock table, used as
  `infra/eks/`'s remote backend. Bootstrap's own state stays local (chicken-and-egg: it creates
  the backend other state uses).

### Monitoring & alerting
- Three CloudWatch alarms on the RDS instance (CPU, free storage, connection count), wired to an
  SNS topic. Optional email subscription via the `alert_email` Terraform variable.
- EKS nodes already span 2 AZs (VPC subnets cover both) — no extra config needed for compute-level
  redundancy. RDS itself is single-AZ (`multi_az = false`) for cost; flipping it is a one-line change.

## Two cluster targets

| | minikube | AWS EKS (`infra/eks/`) |
|---|---|---|
| Purpose | local dev/demo, free | "real cloud" verification |
| Provisioning | `minikube start` | Terraform (`terraform-aws-modules/vpc` + `.../eks`), remote state |
| Data tier | in-cluster Postgres (`postgres.enabled: true`) | RDS (`postgres.enabled: false`, default) |
| Storage class (if in-cluster) | `standard` (hostpath) | `gp2` (EBS, via `aws-ebs-csi-driver` addon) |
| Cost | free | ~$150/month if left running (EKS + RDS + NAT) |
| Sealed Secret | encrypted for minikube's controller key | re-sealed for EKS's controller key |

Full EKS setup/teardown steps: [eks-migration.md](eks-migration.md).
