output "associations" {
  value = {
    for k, a in aws_eks_pod_identity_association.this : k => {
      association_id  = a.association_id
      association_arn = a.association_arn
      namespace       = a.namespace
      service_account = a.service_account
      role_arn        = a.role_arn
    }
  }
  description = "All Pod Identity associations created, keyed by the friendly name"
}
