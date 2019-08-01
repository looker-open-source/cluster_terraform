### Important! ### 
# You must fill in the form at https://download.looker.com/validate to validate your license key and accept the EULA before running this script
variable "looker_license_key" {
  default = "" # your Looker license key
}

variable "technical_contact_email" {
  default = "" # your organization's technical contact for Looker
}

variable "node_count" {
    default = 1
}
variable "instance_type" {
    default = "Standard_D1_v2"
}
variable "location" {
    default = "eastus"
}
variable "os_publisher" {
    default = "RedHat"
}
variable "os_offer" {
    default = "RHEL"
}
variable "os_sku" {
    default = "7.6"
}
variable "provisioning_script" {
    default = "rhel7" # The setup script must match the offer/SKU above!
}