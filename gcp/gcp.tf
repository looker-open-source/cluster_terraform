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

provider tls {
  version = "~> 2.0"
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
    type = "ssh"
    user = "${var.ssh_username}"
    private_key = "${file("~/.ssh/google_compute_engine")}"
  }

  provisioner "file" {
    source      = "${var.provisioning_script}/${var.provisioning_script}"
    destination = "/tmp/${var.provisioning_script}"
  }
  provisioner "remote-exec" {    
    # Set up Looker!
    inline = [
      "sleep 10",

      "export LOOKER_LICENSE_KEY=${var.looker_license_key}",
      "export LOOKER_TECHNICAL_CONTACT_EMAIL=${var.technical_contact_email}",
      "export SHARED_STORAGE_SERVER=${google_filestore_instance.looker.networks.0.ip_addresses.0}",
      "export DB_SERVER=${google_sql_database_instance.looker.ip_address.0.ip_address}",
      "export DB_USER=looker",
      "export DB_LOOKER_PASSWORD=\"${random_id.database-password.hex}\"",
      "export NODE_COUNT=${count.index}",

      "chmod +x /tmp/${var.provisioning_script}",
      "/bin/bash /tmp/${var.provisioning_script}",
    ]
  } 
}

output "Load_Balanced_Host" {
  value = "Started https://${google_compute_address.looker.address}:9999 (you will need to wait a few minutes for the instance to become available and you need to accept the unsafe self-signed certificate)"
}