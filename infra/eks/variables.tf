variable "region" {
  type    = string
  default = "ap-south-1"
}

variable "cluster_name" {
  type    = string
  default = "project3-eks"
}

variable "cluster_version" {
  type = string
  # 1.30 was already in EXTENDED_SUPPORT (ends 2026-07-23, ~1 week away
  # as of this change) and didn't meet Linkerd's current minimum (1.31+)
  # either - bumped to 1.36, the newest version in STANDARD_SUPPORT at
  # the time of this change (confirmed via
  # `aws eks describe-cluster-versions`), not just "next version up."
  default = "1.36"
}

variable "node_instance_type" {
  type    = string
  # t3.small (single node) was sized for this repo's own demo app.
  # Project 13 lands the full Projects 5-12 stack here (ArgoCD, Kyverno,
  # Falco, Linkerd, Vault, Chaos Mesh, LGTM observability, Velero) -
  # t3.small already OOM'd once on minikube under a lighter load
  # (Project 8's incident, see Project-8's troubleshooting notes).
  # m5.large was the original choice (non-burstable, avoids T-series
  # CPU-credit throttling under this stack's sustained load - Prometheus/
  # Loki ingestion, Falco's eBPF probe, Kyverno's per-request admission
  # checks). Actual apply failed: this account only permits launching
  # Free-Tier-eligible instance types (a real account-level restriction,
  # confirmed via `aws ec2 describe-instance-types
  # --filters Name=free-tier-eligible,Values=true`). m7i-flex.large is
  # on that list and matches the same reasoning - 2 vCPU/8GiB,
  # BurstablePerformanceSupported=false - so it's the closest available
  # substitute, not a downgrade in kind, just in what this account allows.
  default = "m7i-flex.large"
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm notifications (leave empty to skip the subscription)"
  type        = string
  default     = ""
}
