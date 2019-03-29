variable "project" {
  default = "looker-terraform"
}

variable "billing_account" {
  default = "" # your GCP billing account ID
}

variable "org_id" {
  default = "" # your GCP organization ID 
}

variable "ssh_username" {
  default = "" # the SSH username used by gcloud
}

variable "region" {
  default = "us-west1"
}

variable "instance_name" {
  default = "cluster-node"
}

variable "vm_type" {
  default = "n1-standard-2"
}

variable "db_type" {
  default = "db-n1-standard-1"
}

variable "os" {
  default = "ubuntu-1804-bionic-v20190320"
}

variable "looker_version" {
  default = "6.8"
}

variable "instance_count" {
  default = "3"
}