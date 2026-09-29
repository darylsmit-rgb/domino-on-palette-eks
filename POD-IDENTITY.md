# Pod Identity setup for Domino on Palette-managed EKS

**Audience:** engineers whose EKS workload clusters use **EKS Pod Identity**
(rather than IRSA) for AWS API access. If your cluster is on IRSA, skip
this doc — the existing pack values already have the SA
`eks.amazonaws.com/role-arn` annotations you need.

**Applies to:** every place a Domino component needs to reach AWS (S3, KMS,
EFS mount, ECR pull, EC2 describe). The AWS-side setup differs between
IRSA and Pod Identity; the role ARNs consumed by the packs and by the
Domino CR are the same shape either way.

## When to prefer Pod Identity

- **EKS 1.28+** (Pod Identity add-on GA'd in 1.28, matured through 1.34+)
- **You want the OIDC provider stack out of your account** (no
  `iam_openid_connect_provider`, no `sts:AssumeRoleWithWebIdentity` trust)
- **Palette-managed EKS on newer minors** where the `eks-pod-identity-agent`
  addon is healthy end-to-end (not the case on all EKS versions —
  verify your cluster before committing)

If Pod Identity turns out to be misbehaving on your cluster version,
static IAM keys (`credentialType: secret` on the Palette cloud account) is
the safest fallback and doesn't require this doc.

## Prerequisites

- The `eks-pod-identity-agent` EKS add-on is installed and its DaemonSet
  is `3/3 Ready` in `kube-system`:
  ```bash
  kubectl -n kube-system get ds eks-pod-identity-agent
  ```
  If it isn't, install via `aws eks create-addon --cluster-name <c>
  --addon-name eks-pod-identity-agent` (or add it to your Palette
  cluster profile so the reconciler doesn't yank it out).

- Your operator workstation has `aws` CLI v2 with permissions to
  `eks:CreatePodIdentityAssociation` on the target cluster and
  `iam:CreateRole` + `iam:AttachRolePolicy` in the account.

## The trust policy (this is what differs from IRSA)

Every IAM role used by a Domino Pod Identity association has the same
trust policy — replace the OIDC-based IRSA trust with this:

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

The **permission** policies (what S3 buckets, KMS keys, etc. the role
can touch) are IDENTICAL to what IRSA needs — no changes required
compared to Domino's IAM policy docs.

## The three (or four) role→SA associations Domino needs

Match your `domino-cr.yaml` values to these role ARNs. All associations
land in the `domino-platform` namespace unless noted.

| Role purpose | Domino CR field | Default SA name | Namespace |
|---|---|---|---|
| Operator control-plane (reconciles the CR, pulls agent image) | `spec.…operator_role_arn` | `platform-operator` | `domino-operator` |
| Flyte control-plane (Flyte propeller + scheduler) | `spec.…controlplane_role_arn` | `flyte-controlplane` | `domino-platform` |
| Flyte data-plane (Flyte task pods, actual workflow runs) | `spec.…dataplane_role_arn` | `flyte-dataplane` | `domino-platform` |
| (Optional) fleetcommand-agent Job | — | `fleetcommand-agent` | `domino-platform` |

## The association command (per role)

```bash
CLUSTER_NAME=<your-cluster>
REGION=<us-gov-west-1 | us-gov-east-1 | your-region>
ACCT=<your-aws-account>

# Operator role — namespace domino-operator
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --namespace domino-operator \
  --service-account platform-operator \
  --role-arn "arn:aws-us-gov:iam::${ACCT}:role/domino-cp-operator"

# Flyte control-plane — namespace domino-platform
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --namespace domino-platform \
  --service-account flyte-controlplane \
  --role-arn "arn:aws-us-gov:iam::${ACCT}:role/domino-cp-flyte-cp"

# Flyte data-plane — namespace domino-platform
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --namespace domino-platform \
  --service-account flyte-dataplane \
  --role-arn "arn:aws-us-gov:iam::${ACCT}:role/domino-cp-flyte-dp"
```

Adjust the partition prefix (`arn:aws-us-gov` vs `arn:aws`) to match
your cluster's partition.

## Order of operations

1. **Before attaching the addon profile** — create the roles and
   associations. Waiting until after the operator install starts is fine
   for the Flyte roles (the fleetcommand-agent Job spins them up), but
   the operator's own association needs to be in place BEFORE the
   platform-operator pod comes up or its first S3/ECR call will 403.
2. **Attach the addon profile** — Palette applies the operator manifests
   and the CR. The operator picks up the CR, spawns the fleetcommand-
   agent Job, ~85 app pods roll out.
3. **Verify** — from inside a pod that should have AWS access:
   ```bash
   kubectl -n domino-operator exec -it deploy/platform-operator -- \
     env | grep AWS_
   # expect:
   #   AWS_ROLE_ARN=arn:...:role/domino-cp-operator
   #   AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/.../token
   #   AWS_STS_REGIONAL_ENDPOINTS=regional
   ```
   The two AWS env vars appearing = Pod Identity association is live.

## Difference from what the pack values say

`csi-aws-ebs-values.yaml.tmpl` and `csi-aws-efs-values.yaml.tmpl` in this
repo carry an IRSA-style annotation on the CSI-driver ServiceAccounts:

```yaml
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws-us-gov:iam::<AWS_ACCOUNT_ID>:role/<csi-role>
```

With Pod Identity active, **that annotation is ignored** — the pod picks
up the role from the association instead. You have two clean options:

- **Leave the annotation in place** — it's inert under Pod Identity but
  keeps the pack values IRSA-compatible if you ever migrate. Zero risk.
- **Strip the annotation** — pack values look cleaner and match your
  actual auth path. Do this if you're publishing the pack values to a
  broader audience that might get confused.

Either way, ALSO run `create-pod-identity-association` for the CSI SA:

```bash
aws eks create-pod-identity-association \
  --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --namespace kube-system \
  --service-account ebs-csi-controller-sa \
  --role-arn "arn:aws-us-gov:iam::${ACCT}:role/<csi-ebs-role>"
```

(Same pattern for `efs-csi-controller-sa` in `kube-system` if using EFS.)

## Automating all associations at once

Two ready-to-use options that replace running `create-pod-identity-association`
by hand for each SA. Both cover the five Domino-on-EKS associations (EBS CSI,
EFS CSI, platform-operator, flyte-controlplane, flyte-dataplane):

- **Terraform:** [`terraform/pod-identity/`](./terraform/pod-identity/) —
  declarative module + example tfvars. Fits customer environments where
  cluster provisioning is already IaC. `terraform apply` after the roles
  exist.
- **Bash script:** [`scripts/pod-identity-associations.sh`](./scripts/pod-identity-associations.sh) —
  imperative alternative. Reads env vars (`CLUSTER_NAME`, `REGION`,
  `PARTITION`, `ACCT`), skips already-existing associations, `SKIP_*=1`
  env vars turn off individual entries.

The IAM roles themselves still have to exist beforehand — this
automation only creates the SA→role bindings on EKS, not the roles.

**Field report (Navy OAI, Sep 2026):** customer manually ran
`create-pod-identity-association` for the CSI SAs because the pack values
carry IRSA-style annotations that Pod Identity ignores. Using this
module OR script removes the manual step.

## Common failures

- **`eks-pod-identity-agent` addon in `DEGRADED` state, but pods look Ready
  from AWS console** — check the DaemonSet directly with `kubectl`; the
  addon's status field can lag. If DaemonSet is `3/3` on nodes, it's fine.
- **Pod has `AWS_ROLE_ARN` but AWS calls still 403** — the trust policy
  might still be OIDC-style from a prior IRSA setup. Update the role's
  trust to the block at the top of this doc.
- **Palette-managed EKS reconciler removes the `eks-pod-identity-agent`
  addon** — happens if the addon isn't declared in the cluster's Palette
  profile. Add it to the profile so the reconciler treats it as expected
  state. Documented in the shared Palette runbooks as Rule 5.

## Fallback: static IAM keys

If Pod Identity isn't working on your cluster minor and IRSA isn't
usable either, `credentialType: secret` on the Palette cloud account
takes static IAM user keys and bypasses both mechanisms. It's less
elegant but always works. Domino doesn't care — the operator picks up
the ambient AWS creds from whatever mechanism resolves first.
