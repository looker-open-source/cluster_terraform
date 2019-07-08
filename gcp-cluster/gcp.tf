provider "google" {
  region      = "${var.region}"
}

# Some of the functionality we need isn't offered in the standard Google provider
provider "google-beta"{
  region = "${var.region}"
}

provider random {
  version ="~> 2.0"
}

resource "random_id" "id" {
  byte_length = 4
}

# Create a Google Cloud Platform project
resource "google_project" "project" {
  name = "${var.project}"
  project_id = "${var.project}-${random_id.id.hex}"
  billing_account = "${var.billing_account}"
  org_id = "${var.org_id}"
}

# Enable APIs and services for our new project
resource "google_project_services" "services" {
  project     = "${google_project.project.project_id}"
  services = [
    "cloudresourcemanager.googleapis.com",
    "container.googleapis.com",
    "file.googleapis.com",
    "iam.googleapis.com",
    "compute.googleapis.com",
    "sql-component.googleapis.com",
    "sqladmin.googleapis.com",
    "servicenetworking.googleapis.com",
  ]
}

# Create a virtual private network to contain our resources
resource "google_compute_network" "looker" {
  project = "${google_project.project.project_id}"
  depends_on = ["google_project_services.services"]
  name = "looker"
}

resource "google_compute_subnetwork" "subnet" {
  name          = "looker-subnet-${var.region}"
  project = "${google_project.project.project_id}"
  region        = "${var.region}"
  network       = "${google_compute_network.looker.self_link}"
  ip_cidr_range = "10.0.0.0/16"
}

# Allocate a static IP address for the load balancer
resource "google_compute_address" "looker" {
  project = "${google_project.project.project_id}"
  depends_on = ["google_compute_network.looker"]
  name = "looker-public-ip"
  region = "${var.region}"
}

# Creating an HTTPS health check for a load balancer via API is not currently supported - you need to create one manually!
# https://github.com/hashicorp/terraform/issues/4282
# https://cloud.google.com/load-balancing/docs/health-checks

#resource "google_compute_https_health_check" "https" {
#  name = "looker-https-basic-check"
#  port = "9999"
#  request_path = "/alive"
#  check_interval_sec = 1
#  healthy_threshold = 1
#  unhealthy_threshold = 10
#  timeout_sec = 1
#}

# Create a target pool for the load balancer that assigns the compute instances we are going to create to the load balancer
resource "google_compute_target_pool" "looker" {
  name = "looker-instance-pool"
  project = "${google_project.project.project_id}"
  instances = ["${google_compute_instance.looker.*.self_link}"]
#  health_checks = ["${google_compute_https_health_check.https.name}"]
  region = "${var.region}"
}

# Create a load balancer rule to route inbound traffic on the public IP port 9999 to port 9999 of an instance (for HTTP)
resource "google_compute_forwarding_rule" "https" {
  name = "looker-https-forwarding-rule"
  project = "${google_project.project.project_id}"
  target = "${google_compute_target_pool.looker.self_link}"
  ip_address = "${google_compute_address.looker.address}"
  port_range = "9999"
  region = "${var.region}"
}

# Create a load balancer rule to route inbound traffic on the public IP port 19999 to port 19999 of an instance (for API)
resource "google_compute_forwarding_rule" "api" {
  name = "looker-api-forwarding-rule"
  project = "${google_project.project.project_id}"
  target = "${google_compute_target_pool.looker.self_link}"
  ip_address = "${google_compute_address.looker.address}"
  port_range = "19999"
  region = "${var.region}"
}

# Create a firewall to block all inbound connections to any ports except 22 (SSH) and the ports we defined above
resource "google_compute_firewall" "firewall" {
  name    = "looker-firewall"
  project = "${google_project.project.project_id}"
  network = "${google_compute_network.looker.name}"

  allow {
    protocol = "tcp"
    ports    = ["22","9999","19999"]
  }

  target_tags   = ["looker-firewall"]
  source_ranges = ["0.0.0.0/0"]
}

# Collect the IP addresses for our compute instances so we can set them in the authorized_networks parameter of the google_sql_database_instance resource"
data "null_data_source" "auth_netw_mysql_allowed" {
  count = "${var.instance_count}"

  inputs = {
    name  = "looker-${var.instance_name}-${count.index}"
    value = "${element(google_compute_instance.looker.*.network_interface.0.access_config.0.nat_ip, count.index)}"
  }
}

# Create a Google Cloud SQL instance to host the application database
resource "google_sql_database_instance" "looker" {
  provider      = "google-beta"
  project = "${google_project.project.project_id}"
  name = "looker-database-${random_id.id.hex}"
  database_version = "MYSQL_5_7"
  region = "${var.region}"

  settings {
    tier                        = "${var.db_type}"
    activation_policy           = "ALWAYS"
    authorized_gae_applications = []
    disk_autoresize             = true
    backup_configuration        = [{
      enabled    = true
      start_time = "03:00"
    }]
    ip_configuration {
      ipv4_enabled = "true",
      authorized_networks = [
        "${data.null_data_source.auth_netw_mysql_allowed.*.outputs}",
      ]
    }
    location_preference         = []
    maintenance_window          = [{
      day          = 6
      hour         = 20
      update_track = "stable"
    }]
    disk_size                   = 10
    disk_type                   = "PD_SSD"
    pricing_plan                = "PER_USE"
    replication_type            = "SYNCHRONOUS"
  }

  timeouts {
    create = "60m"
    delete = "60m"
  }
}

# Create the application database in the Cloud SQL instance
resource "google_sql_database" "backend" {
  provider      = "google-beta"
  project = "${google_project.project.project_id}"
  name      = "looker"
  instance  = "${google_sql_database_instance.looker.name}"
  charset   = "utf8mb4"
  collation = "utf8mb4_general_ci"
}

resource "random_id" "database-password" {
  byte_length = 16
}

# Create database user
resource "google_sql_user" "database-user" {
  provider      = "google-beta"
  project = "${google_project.project.project_id}"
  name     = "looker"
  instance = "${google_sql_database_instance.looker.name}"
  host     = "%"
  password = "${random_id.database-password.hex}"
}

# Create a Filestore resource that compute instances can use as a shared filesystem
resource "google_filestore_instance" "looker" {
  provider = "google-beta"
  project = "${google_project.project.project_id}"
  name = "looker-filestore"
  zone = "${var.region}-a"
  tier = "STANDARD"

  file_shares {
    capacity_gb = 1024
    name        = "lookerfiles"
  }

  networks {
    network = "${google_compute_network.looker.name}"
    modes   = ["MODE_IPV4"]
  }
}

# Create the compute instances
resource "google_compute_instance" "looker" {
  project = "${google_project.project.project_id}"
  count        = "${var.instance_count}"
  name         = "looker-${var.instance_name}-${count.index}"
  machine_type = "${var.vm_type}"
  zone = "${var.region}-a"

  tags = [
    "looker-firewall"
  ]

  boot_disk {
      initialize_params {
        image = "${var.os}"
      }
  }

  network_interface {
    subnetwork = "${google_compute_subnetwork.subnet.self_link}"
    subnetwork_project = "${var.ssh_username}-terraform"

    access_config {
    }
  }

  metadata {
    sshKeys = "${var.ssh_username}:${file("~/.ssh/google_compute_engine.pub")}"
  }
}

# Run a provisioning script on the compute instances we created
resource "null_resource" "cluster-nodes" {
  depends_on = ["google_sql_database_instance.looker","google_compute_instance.looker"]

  triggers {
    instance_ids = "${join(",", google_compute_instance.looker.*.id)}"
  }

  connection {
    host = "${element(google_compute_instance.looker.*.network_interface.0.access_config.0.nat_ip, 0)}"
  }

  provisioner "remote-exec" {
    connection {
      type = "ssh"
      user = "${var.ssh_username}"
      private_key = "${file("~/.ssh/google_compute_engine")}"
    }
    
    # Set up Looker!
    inline = [

      "sleep 10",
      # Install required packages
      "sudo apt-get update -y",
      "sudo apt-get install libssl-dev -y",
      "sudo apt-get install cifs-utils -y",
      "sudo apt-get install fonts-freefont-otf -y",
      "sudo apt-get install chromium-browser -y",
      "sudo apt-get install openjdk-8-jdk -y",
      "sudo apt-get install nfs-common -y",
      "sudo apt-get install jq -y",

      # Install the Looker startup script
      "curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/systemd/looker.service -O",
      "export CMD=\"sed -i 's/TimeoutStartSec=500/Environment=CHROMIUM_PATH=\\/usr\\/bin\\/chromium-browser/' looker.service\"",
      "echo $CMD | bash",
      "sudo mv looker.service /etc/systemd/system/looker.service",
      "sudo chmod 664 /etc/systemd/system/looker.service",

      # Configure some impoortant environment settings
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
      "cd /home/looker/looker",

      # Download and install Looker
      "sudo curl -s -i -X POST -H 'Content-Type:application/json' -d '{\"lic\": \"${var.looker_license_key}\", \"email\": \"${var.technical_contact_email}\", \"latest\":\"latest\"}' https://apidownload.looker.com/download -o /home/looker/looker/response.txt",
      "sudo sed -i 1,9d response.txt",
      "sudo chmod 777 response.txt",
      "eula=$(cat response.txt | jq -r '.eulaMessage')",
      "if [[ \"$eula\" =~ .*EULA.* ]]; then echo \"Error! This script was unable to download the latest Looker JAR file because you have not accepted the EULA. Please go to https://download.looker.com/validate and fill in the form.\"; fi;",
      "url=$(cat response.txt | jq -r '.url')",
      "sudo rm response.txt",
      "sudo curl $url -o /home/looker/looker/looker.jar",
      "sudo chown looker:looker looker.jar",
      "sudo curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/looker -O",
      "sudo chmod 0750 looker",
      "sudo chown looker:looker looker",

      # Determine the IP address of this instance so that it can be registered in the cluster
      "export IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')",
      "export CMD=\"sudo sed -i 's/LOOKERARGS=\\\"\\\"/LOOKERARGS=\\\"--no-daemonize -d \\/home\\/looker\\/looker\\/looker-db.yml --clustered -H $IP --shared-storage-dir \\/mnt\\/lookerfiles\\\"/' /home/looker/looker/looker\"",
      "echo $CMD | bash",

      # Create the database credentials file
      "echo \"host: ${google_sql_database_instance.looker.ip_address.0.ip_address}\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"username: looker\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"password: ${random_id.database-password.hex}\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"database: looker\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"dialect: mysql\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"port: 3306\" | sudo tee -a /home/looker/looker/looker-db.yml",

      # Mount the shared file system
      "sudo mkdir -p /mnt/lookerfiles",
      "sudo mount ${google_filestore_instance.looker.networks.0.ip_addresses.0}:/lookerfiles /mnt/lookerfiles",
      "sudo chown looker:looker /mnt/lookerfiles",
      "cat /proc/mounts | grep looker",

      # Start Looker (but wait a while before starting additional nodes, because the first node needs to prepare the application database schema)
      "sudo systemctl daemon-reload",
      "sudo systemctl enable looker.service",
      "if [ ${count.index} -eq 0 ]; then sudo systemctl start looker; else sleep 300 && sudo systemctl start looker; fi",
    ]
  } 
}

output "Load_Balanced_Host" {
  value = "Started https://${google_compute_address.looker.address}:9999 (you will need to wait a few minutes for the instance to become available and you need to accept the unsafe self-signed certificate)"
}