variable "aws_profile" {
    default = "" # your AWS access token, find in ~/.aws/credentials or create new
}

variable "aws_region" {
    default = "us-west-2"
}

variable "technical_email" {
    default = ""
}

variable "license_key" {
    default = ""
}

variable "ssh_key" {
    default = "id.rsa"
}

provider "aws" {
  profile = "${var.aws_profile}"
  region = "${var.aws_region}"
  version = "~> 2.0"
}

provider random {
  version ="~> 2.0"
}

module "dev_cluster" {
  source = "../core"
  looker_license_key = "${var.license_key}"
  technical_contact_email = "${var.technical_email}"
  key = "${var.ssh_key}"
  final_snapshot_skip = true
  environment = "dev"
}

output "dev_host" {
  value = "${module.dev_cluster.Load_Balanced_Host}"
}
