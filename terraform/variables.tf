variable "project_id" {
  type = string
}

variable "auth_key_id" {
  type      = string
  sensitive = true
}

variable "auth_secret" {
  type      = string
  sensitive = true
}

variable "cluster_sa_id" {
  type = string
}

variable "k8s_version" {
  type    = string
  default = "v1.36.2"
}
