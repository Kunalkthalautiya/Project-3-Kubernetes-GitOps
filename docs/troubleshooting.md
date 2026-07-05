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

## Non-bugs worth noting (design decisions, not mistakes)
- **AWS credentials and a GitHub PAT were pasted directly into chat** during this project's setup.
  Both were treated as compromised on sight: verified whether they worked, then the user was told
  to rotate/deactivate them regardless of validity. Chat transcripts are not a safe credential
  channel — prefer `aws configure` / `gh auth login` run locally, never pasted.
- **Terraform state and `.terraform/` are gitignored**, not committed — state files can contain
  sensitive values, and a real setup would use a remote backend (S3 + DynamoDB) instead of local
  state, as called out in the README's "Next steps".
