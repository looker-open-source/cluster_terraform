### Important! ### 
# You must fill in the form at https://download.looker.com/validate to validate your license key and accept the EULA before running this script
variable "looker_license_key" {
  default = "" # your Looker license key
}

variable "technical_contact_email" {
  default = "" # your organization's technical contact for Looker
}

variable "subscription_id" {
    default = "" # your Azure subscription ID, retrieve with `az account show | grep "id"`
}

variable "count" {
    default = 2
}
variable "instance_type" {
    default = "Standard_D1_v2"
}
variable "location" {
    default = "eastus"
}
