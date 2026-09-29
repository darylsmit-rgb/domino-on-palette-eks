#!/usr/bin/env bash
#
# Bash alternative to terraform/pod-identity/ for customers who prefer
# imperative + read-write access is already available in this shell.
#
# Same effect as `terraform apply` on the module: creates the five Pod
# Identity associations Domino on Palette-EKS needs so CSI + Domino
# ServiceAccounts pick up AWS credentials at pod start.
#
# The IAM roles referenced here must already exist with a
# pods.eks.amazonaws.com trust policy (see POD-IDENTITY.md).
#
# Usage:
#   export CLUSTER_NAME=domino-oai-il5
#   export REGION=us-gov-west-1
#   export PARTITION=aws-us-gov            # or "aws" for commercial
#   export ACCT=123456789012
#   ./scripts/pod-identity-associations.sh
#
# Skip an association by exporting SKIP_<name>=1 (e.g., SKIP_efs_csi=1).

set -euo pipefail

: "${CLUSTER_NAME:?export CLUSTER_NAME}"
: "${REGION:?export REGION}"
: "${PARTITION:=aws-us-gov}"
: "${ACCT:?export ACCT}"

# Association table: key | namespace | service-account | role-name
ASSOCIATIONS=(
  "ebs_csi:kube-system:ebs-csi-controller-sa:domino-ebs-csi"
  "efs_csi:kube-system:efs-csi-controller-sa:domino-efs-csi"
  "platform_operator:domino-operator:platform-operator:domino-cp-operator"
  "flyte_controlplane:domino-platform:flyte-controlplane:domino-cp-flyte-cp"
  "flyte_dataplane:domino-platform:flyte-dataplane:domino-cp-flyte-dp"
)

for row in "${ASSOCIATIONS[@]}"; do
  IFS=: read -r key namespace sa role <<<"$row"
  skip_var="SKIP_${key}"

  if [[ -n "${!skip_var:-}" ]]; then
    echo "SKIP  $key ($namespace/$sa)"
    continue
  fi

  role_arn="arn:${PARTITION}:iam::${ACCT}:role/${role}"

  # Idempotence: check whether an association already exists for this SA
  existing=$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --namespace "$namespace" --service-account "$sa" \
    --query 'associations[0].associationId' --output text 2>/dev/null || echo "None")

  if [[ "$existing" != "None" && "$existing" != "" ]]; then
    echo "SKIP  $key — already associated (id=$existing)"
    continue
  fi

  echo "CREATE $key → $namespace/$sa → $role_arn"
  aws eks create-pod-identity-association \
    --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --namespace "$namespace" --service-account "$sa" \
    --role-arn "$role_arn" \
    --output json | jq -r '.association | "  → \(.associationId)"'
done

echo
echo "Done. Verify from inside a pod:"
echo "  kubectl -n kube-system exec deploy/ebs-csi-controller -- env | grep AWS_"
echo "  kubectl -n domino-operator exec deploy/platform-operator -- env | grep AWS_"
