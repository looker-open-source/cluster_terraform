provider "google" {
  region      = "${var.region}"
}

provider "google-beta"{
  region = "${var.region}"
}

resource "random_id" "id" {
  byte_length = 4
}

resource "google_project" "project" {
  name = "${var.project}"
  project_id = "${var.project}-${random_id.id.hex}"
  billing_account = "${var.billing_account}"
  org_id = "${var.org_id}"
}

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

resource "google_compute_address" "looker" {
  project = "${google_project.project.project_id}"
  depends_on = ["google_compute_network.looker"]
  name = "looker-public-ip"
  region = "${var.region}"
}

# Creating HTTPS health checks via API are not supported - you need to create one manually!
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

resource "google_compute_target_pool" "looker" {
  name = "looker-instance-pool"
  project = "${google_project.project.project_id}"
  instances = ["${google_compute_instance.looker.*.self_link}"]
#  health_checks = ["${google_compute_https_health_check.https.name}"]
  region = "${var.region}"
}

resource "google_compute_forwarding_rule" "https" {
  name = "looker-https-forwarding-rule"
  project = "${google_project.project.project_id}"
  target = "${google_compute_target_pool.looker.self_link}"
  ip_address = "${google_compute_address.looker.address}"
  port_range = "9999"
  region = "${var.region}"
}

resource "google_compute_forwarding_rule" "api" {
  name = "looker-api-forwarding-rule"
  project = "${google_project.project.project_id}"
  target = "${google_compute_target_pool.looker.self_link}"
  ip_address = "${google_compute_address.looker.address}"
  port_range = "19999"
  region = "${var.region}"
}

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

data "null_data_source" "auth_netw_mysql_allowed" {
  count = "${var.instance_count}"

  inputs = {
    name  = "looker-${var.instance_name}-${count.index}"
    value = "${element(google_compute_instance.looker.*.network_interface.0.access_config.0.nat_ip, count.index)}"
  }
}

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

resource "google_sql_user" "database-user" {
  provider      = "google-beta"
  project = "${google_project.project.project_id}"
  name     = "looker"
  instance = "${google_sql_database_instance.looker.name}"
  host     = "%"
  password = "${random_id.database-password.hex}"
}

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
      "if [ ${count.index} -eq 0 ]; then sudo systemctl start looker; else sleep 240 && sudo systemctl start looker; fi",
    ]
  } 
}

output "Load Balanced Host" {
  value = "Listening on https://${google_compute_address.looker.address}:9999 (you will need to accept the unsafe self-signed certificate)"
}