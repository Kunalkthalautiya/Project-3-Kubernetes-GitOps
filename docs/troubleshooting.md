# Troubleshooting Log

Every real bug hit while building this, in order, with root cause and fix. Kept because "what
broke and how you fixed it" is more useful — to future-you and to an interviewer — than a log of
what worked on the first try.

## 1. `kubectl apply` failed on ArgoCD's CRDs
**Symptom**: `The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes`.
**Cause**: `kubectl apply` stores the previous config in an annotation for 3-way diffing; ArgoCD's
CRDs are large enough to exceed the 256KB annotation limit.
**Fix**: `kubectl apply --server-side --force-conflicts` instead — server-side apply doesn't use
that annotation.

## 2. Dumb HTTP git protocol didn't work with ArgoCD
**Symptom** (early local-only iteration, before the GitHub repo existed): `failed to list refs: unexpected EOF`.
**Cause**: serving a bare repo via plain `python -m http.server` only supports git's legacy "dumb"
HTTP protocol; ArgoCD's git client expects smart HTTP (or git://).
**Fix**: switched to `git daemon` (git:// protocol) for the local-only phase; this whole problem
went away once the project moved to a real GitHub repo.

## 3. Wrong `trivy-action` version pinned in CI
**Symptom**: `Unable to resolve action 'aquasecurity/trivy-action@0.24.0', unable to find version '0.24.0'`.
**Cause**: guessed a plausible-looking version tag instead of checking what's actually published.
**Fix**: `gh api repos/aquasecurity/trivy-action/tags --jq '.[0:5][].name'` to get real tags, pinned
to `v0.36.0`.

## 4. Postgres readiness/liveness probes always failed
**Symptom**: `FATAL: role "$(POSTGRES_USER)" does not exist` in Postgres logs, repeating every few
seconds; pod technically became `Ready` after Kubernetes gave up enforcing the check pattern, but
the probe itself never actually passed.
**Cause**: `exec.command: ["pg_isready", "-U", "$(POSTGRES_USER)"]` — the `$(VAR)` substitution
syntax is a Kubernetes-specific expansion that only applies to a container's `command`/`args`
fields. Probe `exec.command` runs the literal argv with no shell and no substitution, so
`$(POSTGRES_USER)` was passed to `pg_isready` as a literal, unexpanded string.
**Fix**: `["sh", "-c", "pg_isready -U $POSTGRES_USER"]` — invoke a shell explicitly so *it* expands
the env var.

## 5. GitOps commit-back push rejected
**Symptom**: `git push` rejected with "fetch first" — remote had commits (the CI bot's own
image-tag bump) that weren't pulled locally yet.
**Cause**: normal concurrent-writer conflict — the bot commits directly to `main` from CI, and the
local clone was behind.
**Fix**: `git pull --rebase` before pushing. Not a design flaw, just a reminder that a repo with an
automated writer needs the human writer to pull before pushing.

## 6. StatefulSet `volumeClaimTemplates` can't be updated in place
**Symptom**: ArgoCD `Application` stuck `OutOfSync` on the `postgres` StatefulSet indefinitely,
even with `selfHeal: true`; the live PVC kept the old `storageClassName` after a values change.
**Cause**: `volumeClaimTemplates` is an immutable field on `StatefulSet` — the Kubernetes API
rejects in-place updates to it, so ArgoCD's normal `kubectl apply`-style sync can't reconcile the
diff.
**Fix**: `kubectl delete statefulset postgres` (and the stale PVC) and let ArgoCD's automated sync
recreate both fresh from the current chart. Data loss is expected/acceptable here since it was a
brand-new demo database; in a real system you'd snapshot first.

## 7. EKS: node pod-density limit
See [eks-migration.md](eks-migration.md#1-tsmall-pod-density-limit) — `t3.small` maxes out at 11
pods; scaled the node group to 2 nodes.

## 8. EKS: Sealed Secret from minikube didn't decrypt
See [eks-migration.md](eks-migration.md#2-sealed-secrets-are-cluster-specific) — Sealed Secrets
keys are per-controller-instance; had to re-seal for EKS's controller.

## 9. EKS: Postgres PVC stuck `Pending` forever
See [eks-migration.md](eks-migration.md#3-no-default-ebs-csi-driver-wrong-storage-class) — no EBS
CSI driver installed by default, and minikube's `standard` storage class doesn't exist on EKS.

## 10. Wrong RDS engine version guessed
See [eks-migration.md](eks-migration.md#4-rds-engine-version-not-available-in-this-region) —
`postgres 16.4` doesn't exist in `ap-south-1`; checked actually-available versions via
`aws rds describe-db-engine-versions` instead of guessing.

## 11. Argo CD Image Updater install manifest 404
**Symptom**: `kubectl apply -f .../argocd-image-updater/stable/manifests/install.yaml` → 404.
**Cause**: assumed the same `manifests/install.yaml` path convention as ArgoCD's own repo; this
project keeps its install manifest at `config/install.yaml` instead, and has no `stable` branch
alias — needs a real tag (e.g. `v1.2.2`).
**Fix**: checked the repo's actual contents (`gh api repos/.../contents/config`) before guessing
another path, then pinned to `https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/v1.2.2/config/install.yaml`.

## 12. Staging Application stuck on a stale git revision
**Symptom**: `gitops-demo-app-staging` failed with `values-staging.yaml: no such file or directory`
even though the file was already committed and pushed to GitHub.
**Cause**: ArgoCD's repo-server had cached an older commit from before the file existed; the
`Application`'s `status.sync.revision` showed the branch name (`main`) rather than a resolved
commit SHA, a sign the comparison was stale.
**Fix**: `kubectl patch application ... -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`
to force a fresh clone/compare instead of waiting for the next poll interval.

## 13. RDS in a private subnet — no `psql` from a laptop
See [eks-migration.md](eks-migration.md#6-rds-is-in-a-private-subnet--no-direct-psql-from-a-laptop)
— had to run `CREATE DATABASE` from a throwaway pod inside the cluster, not from the local machine.

## Non-bugs worth noting (design decisions, not mistakes)
- **AWS credentials and a GitHub PAT were pasted directly into chat** during this project's setup.
  Both were treated as compromised on sight: verified whether they worked, then the user was told
  to rotate/deactivate them regardless of validity. Chat transcripts are not a safe credential
  channel — prefer `aws configure` / `gh auth login` run locally, never pasted.
- **Terraform state now lives in S3 + DynamoDB** (`infra/bootstrap/`), migrated from local state
  with `terraform init -migrate-state`. Local `.tfstate` files are gitignored regardless — they
  can contain sensitive values and shouldn't be committed even temporarily.
- **RDS runs single-AZ, not Multi-AZ**, and the CI "commit-back" pattern was fully replaced (not
  left running alongside Image Updater) — both are one-line/one-annotation changes flagged in the
  README rather than half-implemented in parallel with their replacements.
