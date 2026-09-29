# Cluster profile examples — real exports from a working Palette install

These three JSON files are the actual `/v1/clusterprofiles/{uid}/export`
payloads from a Palette mgmt-plane that runs Domino on Palette-EKS
end-to-end. Sanitized to strip account-specific identifiers and secrets;
placeholders in `<UPPERCASE>` are what a customer substitutes for their
environment before importing.

## Files

| File | Type | Purpose |
|---|---|---|
| [`domino-v2.json`](domino-v2.json) | **cluster profile** (host) | OS + K8s + CNI + CSI — the infra layer stack for Domino. 4 packs at layers os/k8s/cni/csi. Equivalent to `CLUSTER-PROFILE-TEMPLATE.yaml` at the repo root, but as a real export. |
| [`domino-operator.json`](domino-operator.json) | **cluster profile** (add-on) | The Domino platform-operator + CRDs as an add-on profile. Layer 1 of the Domino-as-add-on pattern in `DOMINO-ADDON-LAYERS.md`. |
| [`domino-cr-manifest.json`](domino-cr-manifest.json) | **cluster profile** (add-on) | The Domino CR that the operator reconciles → runs `fleetcommand-agent` → installs Domino. Layer 2 of the add-on pattern. Contains hostname, S3 buckets, IAM role ARNs, image registry — all placeholders. |

## Placeholders to substitute

Every occurrence of `<...>` needs a real value from your environment:

| Placeholder | Example real value | Where it comes from |
|---|---|---|
| `<AWS_ACCOUNT_ID>` | `123456789012` | Your AWS account number |
| `<ECR_PREFIX>` | `mycompany-domino` | Your chosen ECR namespace / prefix |
| `<PACK_REGISTRY>` | `ecr` or your registry name | The pack registry name in Palette → System Console → Registries |
| `<PALETTE_HOST>` | `palette.mycompany.local` | Your Palette mgmt-plane root domain (if referenced anywhere) |
| `<PALETTE_TENANT>` | `palette-XYZ` | Your Palette tenant identifier |
| `<KMS_KEY_ID>` | `12345678-1234-1234-1234-123456789012` | The KMS key ID for Domino S3 bucket encryption |

Quick `sed` pass gets fully-hydrated payloads ready to POST:

```bash
sed -e 's/<AWS_ACCOUNT_ID>/123456789012/g' \
    -e 's/<ECR_PREFIX>/mycompany-domino/g' \
    -e 's/<PACK_REGISTRY>/ecr/g' \
    -e 's/<KMS_KEY_ID>/your-kms-key-id/g' \
    examples/domino-v2.json > /tmp/domino-v2.hydrated.json
```

## Importing via API

These files are the export format Palette's API produces. Import path:

```bash
# hydrate first (see above), then:
curl -k -H "ApiKey: $PALETTE_API_KEY" \
     -H "Content-Type: application/json" \
     -d @/tmp/domino-v2.hydrated.json \
     https://$PALETTE_HOST/v1/clusterprofiles/import
```

Response returns the new profile UID; use it to attach to a cluster.

## Importing via UI

Same content works for **Cluster Profiles → Add Cluster Profile →
Import from File**. Palette detects the export shape and skips the
raw ClusterProfile-YAML validation.

## How this differs from CLUSTER-PROFILE-TEMPLATE.yaml

The root-level `CLUSTER-PROFILE-TEMPLATE.yaml` (and its JSON conversion)
is the **raw ClusterProfile CR shape** — has `apiVersion` +
`kind: ClusterProfile` at the top, `spec.packs[]` inline. That's designed
for the "paste as YAML in UI" flow, and works but requires the customer
to fill in each pack values inline.

These export-shaped payloads have `spec.template.packs[]` (extra
`template` wrapping) and inline the pack values as strings — that's the
shape the `/import` API produces and consumes. They're closer to how
the profile actually lives on the mgmt-plane once installed.

Use whichever matches your tooling. Both do the same thing at the end.

## What was scrubbed

- Account-specific: AWS account ID, ECR registry prefix
- Palette instance-specific: mgmt-plane hostname, tenant slug, pack registry name
- Environment-specific: KMS key IDs
- Any base64-encoded pull secrets or tokens (checked; none survived the export)

Anything customer-safe (image tags, layer names, namespaces, service account
names, chart versions, resource limits, Domino version) stays intact — that's
the whole point of the example.
