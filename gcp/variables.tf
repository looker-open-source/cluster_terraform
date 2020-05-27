### Important! ### 
# You must fill in the form at https://download.looker.com/validate to validate your license key and accept the EULA before running this script
variable "looker_license_key" {
  default = "" # your Looker license key
}

variable "technical_contact_email" {
  default = "" # your organization's technical contact for Looker
}

variable "project" {
  default = "looker-terraform"
}

variable "billing_account" {
  default = "" # your GCP billing account ID, retrieve with `gcloud organizations list`
}

variable "org_id" {
  default = "" # your GCP organization ID, retrieve with `gcloud beta billing accounts list`
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

variable "instance_count" {
  default = "1"
}

variable "provisioning_script" {
    default = "" # The setup script must match the AMI!
                 # AWS and GCP setup scripts are equivalent, use setup-ubuntu-18.04.sh
                 # You must copy that script from the /aws folder to this /gcp folder
}
