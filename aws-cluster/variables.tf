variable "aws_access_key" {
    default = "" # your AWS access token
}

variable "aws_secret_key" {
    default = "" # your AWS secret
}

variable "aws_region" {
    default = "us-west-2"
}

variable "instances" {
    default = 3
}

variable "looker_version" {
    default = "6.8"
}

variable "db_instance_type" {
    default = "db.t2.medium"
}

variable "ec2_instance_type" {
    default = "t2.medium"
}

variable "ami_id" {
    default = "ami-0bbe6b35405ecebdb" # Ubuntu 18.04 x86
}