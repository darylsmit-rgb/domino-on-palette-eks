variable "cluster_name" {
  description = "EKS cluster name where the Pod Identity associations get created"
  type        = string
}

variable "region" {
  description = "AWS region of the cluster (e.g., us-gov-west-1, us-east-1)"
  type        = string
}

variable "associations" {
  description = <<-EOT
    Map of Pod Identity associations to create. Key is a friendly name; value is
    {namespace, service_account, role_arn}. The IAM role must exist beforehand
    and have a trust policy allowing pods.eks.amazonaws.com (see POD-IDENTITY.md).

    See terraform.tfvars.example for the standard Domino + CSI shape.
  EOT
  type = map(object({
    namespace       = string
    service_account = string
    role_arn        = string
  }))
}
