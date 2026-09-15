provider "cloudru" {
  project_id  = var.project_id
  auth_key_id = var.auth_key_id
  auth_secret = var.auth_secret

  endpoints = {
    iam_endpoint               = "iam.api.cloud.ru:443"
    compute_endpoint           = "compute.api.cloud.ru:443"
    mk8s_endpoint              = "mk8s.api.cloud.ru:443"
    vpc_endpoint               = "vpc.api.cloud.ru:443"
    dns_endpoint               = "dns.api.cloud.ru:443"
    nlb_endpoint               = "nlb.api.cloud.ru:443"
    artifact_registry_endpoint = "ar.api.cloud.ru:443"
  }
}
