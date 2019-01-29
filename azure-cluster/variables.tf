variable "count" {default = 2} # The number of app server instances to spin up
variable "instance_type" {default = "Standard_D1_v2"} # Azure instance type
variable "location" {default = "eastus"} # Which Azure region?
variable "domainprefix" {default = "dg"} # Choose a unique prefix to ensure there are no DNS naming collisions
variable looker_version {default = "6.4"}