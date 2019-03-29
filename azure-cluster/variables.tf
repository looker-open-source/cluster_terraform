variable "subscription_id" {
    default = "" # your Azure subscription ID
}

variable "count" {
    default = 3
}
variable "instance_type" {
    default = "Standard_D1_v2"
}
variable "location" {
    default = "eastus"
}
variable "domainprefix" {
    default = "" # choose a unique prefix to ensure there are no DNS naming collisions
} 
variable looker_version {
    default = "6.8"
}
