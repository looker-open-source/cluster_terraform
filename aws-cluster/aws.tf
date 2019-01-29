provider "aws" {
  access_key = "${var.aws_access_key}"
  secret_key = "${var.aws_secret_key}"
  region     = "${var.aws_region}"
  version = "~> 1.57"
}

# Create a virtual private cloud to contain all these resources
resource "aws_vpc" "looker-env" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support = true
  tags {
    Name = "looker-env"
  }
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
  name        = "looker-subnet-group"
  subnet_ids  = ["${aws_subnet.subnet-looker.*.id}"]
}

# Create the inbound security rules
resource "aws_security_group" "ingress-all-looker" {
  name = "allow-all-sg"
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
  key_name   = "key"
  public_key = "${file("~/.ssh/id_rsa.pub")}" # this file must be an existing public key!
}

# Create a parameter group to specify recommended RDS settings for the Looker application database 
resource "aws_db_parameter_group" "looker_db_parameters" {

  name = "customer-internal-57-utf8mb4"
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
  db_subnet_group_name   = "looker-subnet-group"
  parameter_group_name = "${aws_db_parameter_group.looker_db_parameters.name}"
  vpc_security_group_ids = ["${aws_security_group.ingress-all-looker.id}"]
  backup_retention_period = 5
}

# Create a shared NFS file system and mount target
resource "aws_efs_file_system" "looker-efs-fs" {
  creation_token   = "looker-efs-token"
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
  ami           = "ami-0bbe6b35405ecebdb" # Ubuntu 18.04 x86
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
  provisioner "remote-exec" {
    connection {
      type = "ssh"
      user = "ubuntu"
      private_key = "${file("~/.ssh/id_rsa")}"
      timeout = "1m"
      agent = true
    }

    # Set up Looker!
    inline = [

      # Install required packages
      "sudo apt-get update -y",
      "sudo apt-get install libssl-dev -y",
      "sudo apt-get install cifs-utils -y",
      "sudo apt-get install fonts-freefont-otf -y",
      "sudo apt-get install chromium-browser -y",
      "sudo apt-get install nfs-common -y",
      
      # Uncomment the following line if connecting to AWS Redshift:
      #"sudo ip link set dev eth0 mtu 1500",

      # Install the Looker startup script
      "curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/systemd/looker.service -O",
      "sudo mv looker.service /etc/systemd/system/looker.service",
      "sudo chmod 664 /etc/systemd/system/looker.service",

      # Configure some impoortant environment settings
      "sudo sed -i 's/TimeoutStartSec=500/TimeoutStartSec=500\nEnvironment=CHROMIUM_PATH=\\/usr\\/bin\\/chromium-browser/' /etc/systemd/system/looker.service",
      "echo \"Environment=CHROMIUM_PATH=/usr/bin/chromium-browser\" | sudo tee -a /etc/systemd/system/looker.service",
      "echo \"net.ipv4.tcp_keepalive_time=200\" | sudo tee -a /etc/sysctl.conf",
      "echo \"net.ipv4.tcp_keepalive_intvl=200\" | sudo tee -a /etc/sysctl.conf",
      "echo \"net.ipv4.tcp_keepalive_probes=5\" | sudo tee -a /etc/sysctl.conf",
      "echo \"looker     soft     nofile     4096\" | sudo tee -a /etc/security/limits.conf",
      "echo \"looker     hard     nofile     4096\" | sudo tee -a /etc/security/limits.conf",

      # Configure user and group permissions
      "sudo groupadd looker",
      "sudo useradd -m -g looker looker",
      "sudo mkdir /home/looker/looker",
      "sudo chown looker:looker /home/looker/looker",
      "cd /home/looker",

      # Download and install the latest version of Oracle Java 1.8
      "sudo curl -L -b \"oraclelicense=a\" https://download.oracle.com/otn-pub/java/jdk/8u201-b09/42970487e3af4f5aa5bca3f542482c60/jdk-8u201-linux-x64.tar.gz -O",
      "sudo tar zxvf jdk-8u201-linux-x64.tar.gz",
      "sudo chown looker:looker -R jdk1.8.0_201",
      "sudo rm jdk-8u201-linux-x64.tar.gz",

      # Download and install Looker
      "cd /home/looker/looker",
      "sudo curl https://s3.amazonaws.com/download.looker.com/aeHee2HiNeekoh3uIu6hec3W/looker-${var.looker_version}-latest.jar -O",
      "sudo mv looker-${var.looker_version}-latest.jar looker.jar",
      "sudo chown looker:looker looker.jar",
      "sudo curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/looker -O",
      "sudo chmod 0750 looker",
      "sudo chown looker:looker looker",

      # Determine the IP address of this instance so that it can be registered in the cluster
      "export IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')",
      "export CMD=\"sudo sed -i 's/LOOKERARGS=\\\"\\\"/LOOKERARGS=\\\"--no-daemonize -d \\/home\\/looker\\/looker\\/looker-db.yml --clustered -H $IP --shared-storage-dir \\/mnt\\/lookerfiles\\\"/' /home/looker/looker/looker\"",
      "echo $CMD | bash",

      # Create the database credentials file
      "echo \"host: ${aws_db_instance.looker-app-db.address}\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"username: looker\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"password: ${random_string.password.result}\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"database: looker\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"dialect: mysql\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"port: 3306\" | sudo tee -a /home/looker/looker/looker-db.yml",

      # Make sure Java 1.8 is the default
      "sudo update-alternatives --install /usr/bin/java java /home/looker/jdk1.8.0_201/bin/java 100",
      "sudo update-alternatives --install /usr/bin/javac javac /home/looker/jdk1.8.0_201/bin/javac 100",

      # Mount the shared file system
      "sudo mkdir -p /mnt/lookerfiles",
      "sudo mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport ${aws_efs_mount_target.efs-mount.0.dns_name}:/ /mnt/lookerfiles",
      "sudo chown looker:looker /mnt/lookerfiles",
      "cat /proc/mounts | grep looker",

      # Start Looker (but wait a while before starting additional nodes, because the first node needs to prepare the application database schema)
      "sudo systemctl daemon-reload",
      "sudo systemctl enable looker.service",
      "if [ ${count.index} -eq 0 ]; then sudo systemctl start looker; else sleep 300 && sudo systemctl start looker; fi",
    ]
  }

  tags {
    Name = "looker"
  }

  lifecycle {
    # Ignore changes to these arguments because of known issues with the Terraform AWS provider:
    ignore_changes = ["private_ip", "root_block_device", "ebs_block_device"]
  }
}

# Create an internet gateway, a routing table, and route associations
resource "aws_internet_gateway" "looker-env-gw" {
  vpc_id = "${aws_vpc.looker-env.id}"
  tags {
    Name = "looker-env-gw"
  }
}

resource "aws_route_table" "route-table-looker-env" {
  vpc_id = "${aws_vpc.looker-env.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.looker-env-gw.id}"
  }
  tags {
    Name = "looker-env-route-table"
  }
}

resource "aws_route_table_association" "subnet-association" {
  subnet_id      = "${aws_subnet.subnet-looker.0.id}"
  route_table_id = "${aws_route_table.route-table-looker-env.id}"
}

# Use an existing certificate if you have one, otherwise, generate a private/public key pair to use for the load balancer SSL

# BEGIN GENERATE AND REGISTER KEY PAIR:
resource "tls_private_key" "looker_private_key" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P384"
}

resource "tls_self_signed_cert" "looker_cert" {
  key_algorithm   = "ECDSA"
  private_key_pem = "${tls_private_key.looker_private_key.private_key_pem}"

  subject {
    common_name  = "${aws_instance.looker-instance.0.public_dns}"
    organization = "Looker Data Sciences Inc."
  }

  validity_period_hours = 8760

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# Register the key pair with AWS IAM
resource "aws_iam_server_certificate" "looker_iam_cert" {
  name_prefix      = "looker-cert"
  certificate_body = "${tls_self_signed_cert.looker_cert.cert_pem}"
  private_key      = "${tls_private_key.looker_private_key.private_key_pem}"

  lifecycle {
    create_before_destroy = true
  }
}
# END GENERATE AND REGISTER KEY PAIR

# Create a load balancer to route traffic to the instances
resource "aws_elb" "looker-elb" {
  name                        = "looker-elb"
  subnets                     = ["${aws_subnet.subnet-looker.0.id}"]
  internal                    = "false"
  security_groups             = ["${aws_security_group.ingress-all-looker.id}"]
  instances                   = ["${aws_instance.looker-instance.*.id}"]
  cross_zone_load_balancing   = true
  idle_timeout                = 3600
  connection_draining         = false
  connection_draining_timeout = 300

  listener = [
    {
      instance_port      = "9999"
      instance_protocol  = "https"
      lb_port            = "443"
      lb_protocol        = "https"
      ssl_certificate_id = "${aws_iam_server_certificate.looker_iam_cert.arn}"
    },
    {
      instance_port      = "19999"
      instance_protocol  = "https"
      lb_port            = "19999"
      lb_protocol        = "https"
      ssl_certificate_id = "${aws_iam_server_certificate.looker_iam_cert.arn}"
    },
  ]

  health_check = [
    {
      target              = "https:9999/alive"
      interval            = 30
      healthy_threshold   = 2
      unhealthy_threshold = 2
      timeout             = 5
    },
  ]
}

# Generate a random database password
resource "random_string" "password" {
  length = 16
  special = true
  override_special = "/@\" "
}

output "Load Balanced Primary URL" {
  value = "Listening on https://${aws_elb.looker-elb.dns_name} (you will need to accept the unsafe self-signed certificate)"
}

