variable "aws_access_key" {default = ""} # add your access token
variable "aws_secret_key" {default = ""} # add your secret key
variable "aws_region" {default = "us-west-2"}
variable instances {default = 3}
variable looker_version {default = "6.4"}
variable db_instance_type {default = "db.t2.medium"}
variable ec2_instance_type {default = "t2.medium"}
