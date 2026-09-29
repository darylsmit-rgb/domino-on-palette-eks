# Pod Identity associations for Domino on Palette-EKS

Terraform module that creates the EKS Pod Identity associations Domino needs
so its ServiceAccounts pick up AWS credentials at pod-start time.

**Prerequisite:** the IAM roles referenced in `terraform.tfvars` must already
exist and have a trust policy for `pods.eks.amazonaws.com`
(`sts:AssumeRole` + `sts:TagSession`). See `POD-IDENTITY.md` at the repo
root for the exact trust JSON and the AWS permissions each role needs.

## What this solves

Palette-installed CSI packs and the Domino operator manifests both use
IRSA-style ServiceAccount annotations (`eks.amazonaws.com/role-arn`).
On EKS clusters with Pod Identity enabled, those annotations are ignored
and pods start with no AWS credentials — CSI provisioning + Domino AWS
API calls silently 403 until associations are created out-of-band.
Field reports (Navy OAI, Sep 2026) confirmed customers were manually
running `aws eks create-pod-identity-association` after install; this
module makes it declarative.

## Usage

```bash
cd terraform/pod-identity
cp terraform.tfvars.example terraform.tfvars   # edit with real values
terraform init
terraform plan
terraform apply
```

Verify from inside a pod after `terraform apply`:

```bash
kubectl -n kube-system exec -it deploy/ebs-csi-controller -- env | grep AWS_
# expect: AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE, AWS_STS_REGIONAL_ENDPOINTS
```

## Standard shape

`terraform.tfvars.example` bundles the five associations Domino on Palette-EKS
typically needs:

| Association | Namespace | SA | What it does |
|---|---|---|---|
| `ebs-csi` | `kube-system` | `ebs-csi-controller-sa` | EBS PVC provisioning for `dominodisk` |
| `efs-csi` | `kube-system` | `efs-csi-controller-sa` | EFS mount for `dominoshared` (RWX) |
| `platform-operator` | `domino-operator` | `platform-operator` | Domino operator reconciles the CR + pulls fleetcommand-agent from ECR |
| `flyte-controlplane` | `domino-platform` | `flyte-controlplane` | Flyte propeller + scheduler |
| `flyte-dataplane` | `domino-platform` | `flyte-dataplane` | Flyte task pods (workflow runs) |

Drop associations you don't need (no EFS → remove `efs-csi`). Add
entries for anything else needing AWS access.

## Ordering vs. Domino install

The **CSI and platform-operator** associations should exist BEFORE you
attach the Domino profile to a cluster — the CSI controllers and the
platform-operator pod come up early in the install sequence and will
403 without an association.

The **Flyte** associations can be created either before or after the
first Domino install runs (Flyte pods appear later, when
fleetcommand-agent runs). Doing it up front is simpler; doing it after
lets you scope roles by observed SA names if you prefer.

## Trust policy reminder (goes on each IAM role)

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "pods.eks.amazonaws.com"},
    "Action": ["sts:AssumeRole", "sts:TagSession"]
  }]
}
```
