resource "aws_eks_pod_identity_association" "this" {
  for_each = var.associations

  cluster_name    = var.cluster_name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = each.value.role_arn
}
