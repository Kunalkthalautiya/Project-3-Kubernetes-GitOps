# EKS Migration

How this app moved from minikube to a real AWS EKS cluster, and how to reproduce or tear it down.

## What `infra/eks/` provisions

Using the community `terraform-aws-modules/vpc` (~> 5.0) and `terraform-aws-modules/eks` (~> 20.0)
modules — the standard way most real orgs stand up EKS, rather than hand-rolling every IAM role:

- A VPC with 2 public + 2 private subnets across 2 AZs, single NAT gateway (cost saving).
- An EKS cluster (`project3-eks`, Kubernetes 1.30) with public endpoint access.
- One managed node group, `t3.small`, desired size configurable (`node_desired_size` variable).
- KMS key for cluster secrets encryption, OIDC provider, IAM roles — all handled by the module.
- An RDS `db.t3.micro` PostgreSQL instance, subnet group, and a security group scoped to allow
  traffic only from the EKS node security group (`module.eks.node_security_group_id`).
- CloudWatch alarms (RDS CPU/storage/connections) + an SNS topic for alerting.
- Remote state in S3 + DynamoDB (`infra/bootstrap/`) instead of a local `terraform.tfstate`.

## Setup

```bash
# One-time: create the remote state backend
cd infra/bootstrap
terraform init
terraform apply -auto-approve

# Then the actual cluster + RDS + monitoring
cd ../eks
terraform init
terraform plan -out=tfplan     # free — creates nothing, just shows what would be created
terraform apply "tfplan"       # NOT free — starts real AWS billing immediately

aws eks update-kubeconfig --region ap-south-1 --name project3-eks
kubectl get nodes              # confirm nodes are Ready
```

Then repeat the ArgoCD + Sealed Secrets + Argo CD Image Updater + repo-creds + imagePullSecret
setup from the main [README](../README.md#local-setup-minikube), pointed at this cluster's
`kubectl` context instead of minikube's. These don't carry over between clusters — see the
gotchas below.

## Cost

Running continuously in `ap-south-1`:

| Resource | ~Monthly cost |
|---|---|
| EKS control plane | $73 ($0.10/hr) |
| 2× `t3.small` nodes | $30 |
| NAT Gateway | $32 + data transfer |
| RDS `db.t3.micro` (single-AZ) | $15 |
| KMS key | $1 |
| CloudWatch alarms + SNS | <$1 |
| **Total** | **~$150** |

Enabling `multi_az = true` on the RDS instance roughly doubles its cost (~$30/month instead of
~$15) in exchange for automatic failover to a standby in a second AZ.

## Gotchas hit during migration (cluster-specific things that don't carry over from minikube)

### 1. `t3.small` pod density limit
EKS enforces a max-pods-per-node limit based on the instance type's ENI/IP capacity —
`t3.small` caps out at 11 pods. ArgoCD (~7 pods) + kube-system (~4-5 pods) already fills that,
leaving no room for the app. Fixed by scaling the node group to 2 nodes:

```bash
aws eks list-nodegroups --cluster-name project3-eks --region ap-south-1
aws eks update-nodegroup-config --cluster-name project3-eks \
  --nodegroup-name <name-from-above> \
  --scaling-config minSize=1,maxSize=2,desiredSize=2 --region ap-south-1
```
Note: the `terraform-aws-modules/eks` module intentionally ignores `desired_size` changes after
initial creation (to avoid fighting the cluster autoscaler), so scaling has to go through the AWS
CLI/console directly, not another `terraform apply`.

### 2. Sealed Secrets are cluster-specific
Each Sealed Secrets controller instance has its own keypair. A `SealedSecret` encrypted for
minikube's controller **cannot** be decrypted by EKS's controller (or vice versa). Moving clusters
means re-sealing:

```bash
kubectl port-forward -n kube-system svc/sealed-secrets-controller 8081:8080 &
curl -s http://localhost:8081/v1/cert.pem -o /tmp/pubcert.pem

kubectl create secret generic gitops-demo-secret -n gitops-demo \
  --from-literal=DEMO_API_KEY=... --from-literal=POSTGRES_USER=... \
  --from-literal=POSTGRES_PASSWORD=... --from-literal=POSTGRES_DB=... \
  --dry-run=client -o yaml > /tmp/plain-secret.yaml

kubeseal --format=yaml --cert=/tmp/pubcert.pem \
  < /tmp/plain-secret.yaml > charts/gitops-demo/templates/sealedsecret.yaml
rm -f /tmp/pubcert.pem /tmp/plain-secret.yaml   # never commit the plaintext
```
Direct `kubeseal --fetch-cert` (no port-forward) works on minikube because the docker driver's
network is host-routable; it is not on EKS, since pod/service IPs live inside the VPC.

### 3. No default EBS CSI driver, wrong storage class
EKS ships a `gp2` `StorageClass` object, but **no controller to actually provision volumes** —
the `aws-ebs-csi-driver` addon isn't installed by default. Also, minikube's `standard` storage
class doesn't exist on EKS at all. Both had to be fixed:

```bash
# storage class: change charts/gitops-demo/values.yaml postgres.storageClassName
#   standard (minikube)  ->  gp2 (EKS)

# EBS CSI driver + permissions for the node role:
aws iam attach-role-policy --role-name <node-role-name> \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
aws eks create-addon --cluster-name project3-eks --addon-name aws-ebs-csi-driver \
  --resolve-conflicts OVERWRITE --region ap-south-1
```
Also: a `StatefulSet`'s `volumeClaimTemplates` is immutable — changing the storage class on an
existing StatefulSet requires deleting and letting ArgoCD (`selfHeal: true`) recreate it, not an
in-place patch.

### 4. RDS engine version not available in this region
`engine_version = "16.4"` failed: `InvalidParameterCombination: Cannot find version 16.4 for
postgres`. AWS only offers specific minor versions per engine/region, and they change over time —
guessing a plausible-looking version fails the same way the `trivy-action` tag guess did (see
[troubleshooting.md](troubleshooting.md)). Fixed by checking what's actually available first:
```bash
aws rds describe-db-engine-versions --engine postgres --region ap-south-1 \
  --query 'DBEngineVersions[?starts_with(EngineVersion, `16.`)].EngineVersion' --output text
```

### 5. Sealed Secrets are namespace-scoped, not just cluster-scoped
Adding a staging environment (separate `gitops-demo-staging` namespace, same cluster) surfaced a
second layer of the Sealed Secrets gotcha above: encryption is bound to a specific *namespace*,
not just a specific cluster. A `SealedSecret` sealed for `gitops-demo` cannot decrypt in
`gitops-demo-staging`, even on the identical cluster/controller. Each namespace needs its own
sealed file (`templates/sealedsecret.yaml` vs `templates/sealedsecret-staging.yaml`), gated by a
`{{- if eq .Values.environment "..." }}` so only one renders per values file.

### 6. RDS is in a private subnet — no direct `psql` from a laptop
Creating the staging environment's separate logical database (`CREATE DATABASE
gitopsdemo_staging`) couldn't be done via `psql` from the local machine — the RDS security group
only allows traffic from the EKS node security group, and RDS itself isn't publicly accessible.
Fixed by running the `CREATE DATABASE` from inside the cluster instead:
```bash
kubectl run psql-tmp --image=postgres:16-alpine --rm -i --restart=Never \
  --env="PGPASSWORD=$DB_PASS" -- \
  psql -h "$RDS_HOST" -U gitopsdemo -d gitopsdemo -c "CREATE DATABASE gitopsdemo_staging;"
```

## Teardown

```bash
cd infra/eks
terraform destroy
```
Do this as soon as you're done verifying/demoing — the cluster bills by the hour whether or not
anything is running on it.
