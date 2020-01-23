# Create a virtual private cloud to contain all these resources
resource "aws_vpc" "looker-env" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support = true
}

# Create elastic IP addresses for our ec2 instances
resource "aws_eip" "ip-looker-env" {
  depends_on = ["aws_instance.looker-instance"]
  count      = "${var.instances}"
  instance   = "${element(aws_instance.looker-instance.*.id, count.index)}"
  vpc        = true
}

# Get a list of all availability zones in this region, we need it to create subnets
data "aws_availability_zones" "available" {}

# Create subnets within each availability zone
resource "aws_subnet" "subnet-looker" {
  count                   = "${length(data.aws_availability_zones.available.names)}"
  vpc_id                  = "${aws_vpc.looker-env.id}"
  cidr_block              = "10.0.${length(data.aws_availability_zones.available.names) + count.index}.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${element(data.aws_availability_zones.available.names, count.index)}"
}

# Create a database subnet group to configure a high-availabilty RDS instance for the Looker application database server
resource "aws_db_subnet_group" "subnet-group-looker" {
  name = "looker-subnet-group-${var.environment}"
  subnet_ids  = "${aws_subnet.subnet-looker.*.id}"
}

# Create the inbound security rules
resource "aws_security_group" "ingress-all-looker" {
  name = "allow-all-sg-${var.environment}"
  vpc_id = "${aws_vpc.looker-env.id}"

  # Looker cluster communication
  ingress {
    cidr_blocks = [
      "10.0.0.0/16" # (private to subnet)
    ]
    from_port = 61616
    to_port = 61616
    protocol = "tcp"
  }

  # Looker cluster communication
  ingress {
    cidr_blocks = [
      "10.0.0.0/16" # (private to subnet)
    ]
    from_port = 1551
    to_port = 1551
    protocol = "tcp"
  }

  # MySQL
  ingress {
    cidr_blocks = [
      "10.0.0.0/16" # (private to subnet)
    ]
    from_port = 3306
    to_port = 3306
    protocol = "tcp"
  }

  # NFS
  ingress {
    cidr_blocks = [
      "10.0.0.0/16" # (private to subnet)
    ]
    from_port = 2049
    to_port = 2049
    protocol = "tcp"
  }

  # SSH
  ingress {
    cidr_blocks = [
      "0.0.0.0/0" # (open to the world)
    ]
    from_port = 22
    to_port = 22
    protocol = "tcp"
  }

  # API
  ingress {
    cidr_blocks = [
      "0.0.0.0/0" # (open to the world)
    ]
    from_port = 19999
    to_port = 19999
    protocol = "tcp"
  }

  # HTTP to reach single nodes
  ingress {
    cidr_blocks = [
      "0.0.0.0/0" # (open to the world)
    ]
    from_port = 9999
    to_port = 9999
    protocol = "tcp"
  }

  # HTTPS
  ingress {
    cidr_blocks = [
      "0.0.0.0/0" # (open to the world)
    ]
    from_port = 443
    to_port = 443
    protocol = "tcp"
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Choose an existing public/private key pair to use for authentication
resource "aws_key_pair" "key" {
  key_name   = "key-${var.environment}"
  public_key = "${file("~/.ssh/${var.key}.pub")}" # this file must be an existing public key!
}

# Create a parameter group to specify recommended RDS settings for the Looker application database 
resource "aws_db_parameter_group" "looker_db_parameters" {

  name = "customer-internal-57-utf8mb4-${var.environment}"
  family = "mysql5.7"

  parameter {
    name  = "character_set_client"
    value = "utf8mb4"
  }
  
  parameter {
    name  = "character_set_connection"
    value = "utf8mb4"
  }
  
  parameter {
    name  = "character_set_database"
    value = "utf8mb4"
  }
  
  parameter {
    name  = "character_set_results"
    value = "utf8mb4"
  }
  
  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }
  
  parameter {
    name  = "collation_connection"
    value = "utf8mb4_general_ci"
  }
  
  parameter {
    name  = "collation_server"
    value = "utf8mb4_general_ci"
  }
  
  parameter {
    name  = "default_password_lifetime"
    value = "0"
  }
  
  parameter {
    name  = "innodb_log_file_size"
    value = "536870912"
    apply_method = "pending-reboot"
  }
  
  parameter {
    name  = "innodb_purge_threads"
    value = "1"
    apply_method = "pending-reboot"
  }
  
  parameter {
    name  = "log_bin_trust_function_creators"
    value = "1"
  }
  
  parameter {
    name  = "max_allowed_packet"
    value = "1073741824"
  }
}

# Create the RDS instance for the Looker application database
resource "aws_db_instance" "looker-app-db" {
  allocated_storage    = 100 # values less than 100GB will result in degraded IOPS performance
  storage_type         = "gp2"
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "${var.db_instance_type}"
  name                 = "looker"
  username             = "looker"
  password             = "${random_string.password.result}"
  db_subnet_group_name   = "${aws_db_subnet_group.subnet-group-looker.name}"
  parameter_group_name = "${aws_db_parameter_group.looker_db_parameters.name}"
  vpc_security_group_ids = ["${aws_security_group.ingress-all-looker.id}"]
  backup_retention_period = 5
  skip_final_snapshot = "${var.final_snapshot_skip}"
}

# Create a shared NFS file system and mount target
resource "aws_efs_file_system" "looker-efs-fs" {
  creation_token   = "looker-efs-token-${var.environment}"
  performance_mode = "generalPurpose"
  encrypted        = "true"
}

resource "aws_efs_mount_target" "efs-mount" {
  file_system_id  = "${aws_efs_file_system.looker-efs-fs.id}"
  subnet_id       = "${aws_subnet.subnet-looker.0.id}"
  security_groups = ["${aws_security_group.ingress-all-looker.id}"]
}

# Create ec2 instances for the Looker application servers
resource "aws_instance" "looker-instance" {
  count         = "${var.instances}"
  ami           = "${var.ami_id}"
  instance_type = "${var.ec2_instance_type}"
  vpc_security_group_ids = ["${aws_security_group.ingress-all-looker.id}"]
  subnet_id = "${aws_subnet.subnet-looker.0.id}"
  associate_public_ip_address = true
  key_name = "${aws_key_pair.key.key_name}"

  root_block_device {
    volume_type           = "gp2"
    volume_size           = "30"
    delete_on_termination = "true"
  }

  ebs_block_device {
    device_name           = "/dev/sdg"
    volume_type           = "gp2"
    volume_size           = "30"
  }
  
  connection {
    host = "${element(aws_instance.looker-instance.*.public_dns, count.index)}"
    type = "ssh"
    user = "ubuntu"
    private_key = "${file("~/.ssh/${var.key}")}"
    timeout = "1m"
    agent = true // must be false on some platforms (Windows?)
  }

  provisioner "file" {
    source      = "${var.provisioning_path}${var.provisioning_script}"
    destination = "/tmp/${var.provisioning_script}"
  }
  provisioner "remote-exec" {
    inline = [
      "sleep 10",

      "export LOOKER_LICENSE_KEY=${var.looker_license_key}",
      "export LOOKER_TECHNICAL_CONTACT_EMAIL=${var.technical_contact_email}",
      "export SHARED_STORAGE_SERVER=${aws_efs_mount_target.efs-mount.dns_name}",
      "export DB_SERVER=${aws_db_instance.looker-app-db.address}",
      "export DB_USER=looker",
      "export DB_PASSWORD=\"${random_string.password.result}\"",
      "export NODE_COUNT=${count.index}",

      "chmod +x /tmp/${var.provisioning_script}",
      "/bin/bash /tmp/${var.provisioning_script}",
   ]
 }

  lifecycle {
    # Ignore changes to these arguments because of known issues with the Terraform AWS provider:
    ignore_changes = ["private_ip", "root_block_device", "ebs_block_device"]
  }
}

# Create an internet gateway, a routing table, and route associations
resource "aws_internet_gateway" "looker-env-gw" {
  vpc_id = "${aws_vpc.looker-env.id}"
}

resource "aws_route_table" "route-table-looker-env" {
  vpc_id = "${aws_vpc.looker-env.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.looker-env-gw.id}"
  }
}

resource "aws_route_table_association" "subnet-association" {
  subnet_id      = "${aws_subnet.subnet-looker.0.id}"
  route_table_id = "${aws_route_table.route-table-looker-env.id}"
}

# Use an existing certificate if you have one, otherwise, generate a private/public key pair to use for the load balancer SSL


data "aws_route53_zone" "zone" {
  name = "${var.domain}."
  private_zone = false
}

resource "aws_acm_certificate" "cert" {
  domain_name = "looker-${var.environment}.${var.domain}"
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  name = "${aws_acm_certificate.cert.domain_validation_options.0.resource_record_name}"
  type = "${aws_acm_certificate.cert.domain_validation_options.0.resource_record_type}"
  zone_id = "${data.aws_route53_zone.zone.zone_id}"
  records = ["${aws_acm_certificate.cert.domain_validation_options.0.resource_record_value}"]
  ttl = 60
}

resource "aws_acm_certificate_validation" "cert" {
  certificate_arn = "${aws_acm_certificate.cert.arn}"
  validation_record_fqdns = ["${aws_route53_record.cert_validation.fqdn}"]
}

# Create a load balancer to route traffic to the instances
resource "aws_elb" "looker-elb" {
  name                        = "looker-elb-${var.environment}"
  subnets                     = ["${aws_subnet.subnet-looker.0.id}"]
  internal                    = "false"
  security_groups             = ["${aws_security_group.ingress-all-looker.id}"]
  instances                   = "${aws_instance.looker-instance.*.id}"
  cross_zone_load_balancing   = true
  idle_timeout                = 3600
  connection_draining         = false
  connection_draining_timeout = 300

  listener {
    instance_port      = "9999"
    instance_protocol  = "https"
    lb_port            = "443"
    lb_protocol        = "https"
    ssl_certificate_id = "${aws_acm_certificate.cert.arn}"
  }

  listener {
    instance_port      = "19999"
    instance_protocol  = "https"
    lb_port            = "19999"
    lb_protocol        = "https"
    ssl_certificate_id = "${aws_acm_certificate.cert.arn}"
  }

  health_check {
    target              = "https:9999/alive"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
  }
}

resource "aws_route53_record" "looker-dns" {
  zone_id = "${data.aws_route53_zone.zone.zone_id}"
  name = "looker-${var.environment}.colinpistell.com"
  type = "A"

  alias {
    name = "${aws_elb.looker-elb.dns_name}"
    zone_id = "${aws_elb.looker-elb.zone_id}"
    evaluate_target_health = false
  }
}

# Generate a random database password
resource "random_string" "password" {
  length = 16
  special = true
  number = true
  min_special = 1
  min_numeric = 1
  min_upper = 1
  override_special = "#%^&*()-="
}

output "Load_Balanced_Host" {
  value = "Started https://${aws_elb.looker-elb.dns_name} (you will need to wait a few minutes for the instance to become available and you need to accept the unsafe self-signed certificate)"
}

