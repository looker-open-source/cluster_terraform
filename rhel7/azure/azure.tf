provider azurerm {
  version = "~> 1.27.0"
}

provider random {
  version ="~> 2.0"
}

resource "random_id" "id" {
  byte_length = 4
}

# Create a resource group to contain everything
resource "azurerm_resource_group" "looker" {
  name     = "cluster-${random_id.id.hex}"
  location = "${var.location}"
}

# Create a virtual network
resource "azurerm_virtual_network" "looker" {
  name                = "lookervn"
  address_space       = ["10.0.0.0/16"]
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"
}

# Create a subnet
resource "azurerm_subnet" "looker" {
  name                 = "lookersub"
  resource_group_name  = "${azurerm_resource_group.looker.name}"
  virtual_network_name = "${azurerm_virtual_network.looker.name}"
  address_prefix       = "10.0.2.0/24"
}

# Create a public IP address to assign to the load balancer
resource "azurerm_public_ip" "looker" {
  name                         = "PublicIPForLB"
  location                     = "${azurerm_resource_group.looker.location}"
  resource_group_name          = "${azurerm_resource_group.looker.name}"
  allocation_method            = "Static"
  domain_name_label            = "cluster-${random_id.id.hex}"
  idle_timeout_in_minutes      = 30
}

# Create public IPs to connect to each instance individually
resource "azurerm_public_ip" "pubip" {
  count                        = "${var.node_count}"
  name                         = "lookerpip-${count.index}"
  location                     = "${azurerm_resource_group.looker.location}"
  resource_group_name          = "${azurerm_resource_group.looker.name}"
  allocation_method            = "Static"
  domain_name_label            = "cluster-${random_id.id.hex}-${count.index}"
  idle_timeout_in_minutes      = 30
}

# Create a load balancer
resource "azurerm_lb" "looker" {
  name                = "lookerlb"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"
  sku                 = "basic"

  frontend_ip_configuration {
    name                 = "PublicIPAddress"
    public_ip_address_id = "${azurerm_public_ip.looker.id}"
  }
}

# Create a backend pool to contain the VMs associated to the load balancer
resource "azurerm_lb_backend_address_pool" "looker" {
  resource_group_name = "${azurerm_resource_group.looker.name}"
  loadbalancer_id     = "${azurerm_lb.looker.id}"
  name                = "BackEndAddressPool"
}

# Create a network interfaces for each of the VMs to use
resource "azurerm_network_interface" "looker" {
  count = "${var.node_count}"
  name                = "lookernic-${count.index}"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  ip_configuration {
    name                          = "lookeripconfiguration${count.index}"
    subnet_id                     = "${azurerm_subnet.looker.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${element(azurerm_public_ip.pubip.*.id, count.index)}"
  }
}

# Associate each network interface to the backend pool for the load balancer
resource "azurerm_network_interface_backend_address_pool_association" "looker" {
  count = "${var.node_count}"
  network_interface_id    = "${element(azurerm_network_interface.looker.*.id, count.index)}"
  ip_configuration_name   = "lookeripconfiguration${count.index}"
  backend_address_pool_id = "${azurerm_lb_backend_address_pool.looker.id}"
}

# Create an instance health probe for the load balancer rule
resource "azurerm_lb_probe" "looker" {
  resource_group_name = "${azurerm_resource_group.looker.name}"
  loadbalancer_id     = "${azurerm_lb.looker.id}"
  name                = "lookerhealthprobe"
  port                = "9999"
  protocol            = "tcp"
}

# Create a load balancer rule to route inbound traffic on the public IP port 443 to port 9999 of an instance
resource "azurerm_lb_rule" "looker" {
  resource_group_name            = "${azurerm_resource_group.looker.name}"
  loadbalancer_id                = "${azurerm_lb.looker.id}"
  name                           = "LBRule"
  protocol                       = "Tcp"
  frontend_port                  = 443
  backend_port                   = 9999
  backend_address_pool_id        = "${azurerm_lb_backend_address_pool.looker.id}"
  probe_id                       = "${azurerm_lb_probe.looker.id}"
  frontend_ip_configuration_name = "PublicIPAddress"
  # This can be a problem - the maximum timeout on Azure is not long enough!
  idle_timeout_in_minutes        = 30
}

# Create a load balancer rule to route inbound traffic on the public IP port 19999 to port 19999 of an instance (for API)
resource "azurerm_lb_rule" "looker1" {
  resource_group_name            = "${azurerm_resource_group.looker.name}"
  loadbalancer_id                = "${azurerm_lb.looker.id}"
  name                           = "LBRuleforAPI"
  protocol                       = "Tcp"
  frontend_port                  = 19999
  backend_port                   = 19999
  backend_address_pool_id        = "${azurerm_lb_backend_address_pool.looker.id}"
  probe_id                       = "${azurerm_lb_probe.looker.id}"
  frontend_ip_configuration_name = "PublicIPAddress"
  idle_timeout_in_minutes        = 30
}

# Create an Azure storage account
resource "azurerm_storage_account" "looker" {
  name                     = "storage${random_id.id.hex}"
  resource_group_name      = "${azurerm_resource_group.looker.name}"
  location                 = "${azurerm_resource_group.looker.location}"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

# Retrieve the keys to the storage account so we can use them later in the provisioning script for the app instances
data "azurerm_storage_account" "looker" {
  depends_on           = ["azurerm_storage_account.looker"]
  name                 = "storage${random_id.id.hex}"
  resource_group_name  = "${azurerm_resource_group.looker.name}"
}

# Create a container within the storage account
resource "azurerm_storage_container" "looker" {
  name                  = "vhds"
  resource_group_name   = "${azurerm_resource_group.looker.name}"
  storage_account_name  = "${azurerm_storage_account.looker.name}"
  container_access_type = "private"
}

# Create a bucket / file share within the container
resource "azurerm_storage_share" "looker" {
  name = "lookerfiles"

  resource_group_name  = "${azurerm_resource_group.looker.name}"
  storage_account_name = "${azurerm_storage_account.looker.name}"

  quota = 50
}

# Create a network security group to restrict port traffic
resource "azurerm_network_security_group" "looker" {
  name                = "lookersg"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  security_rule {
    name                       = "Port_9999"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9999"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Port_443"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Port_19999"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "19999"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

# Create an availability set - not sure if this is actually useful
resource "azurerm_availability_set" "looker" {
  name                = "lookeravailabilityset"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"
}

# Create the virtual machines
resource "azurerm_virtual_machine" "looker" {

  depends_on                       = ["azurerm_availability_set.looker","azurerm_virtual_machine.lookerdb"]

  name                             = "lookerapp-${count.index}"
  location                         = "${azurerm_resource_group.looker.location}"
  resource_group_name              = "${azurerm_resource_group.looker.name}"
  network_interface_ids            = ["${element(azurerm_network_interface.looker.*.id, count.index)}"]
  vm_size                          = "${var.instance_type}"
  count                            = "${var.node_count}"
  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true
  availability_set_id              = "${azurerm_availability_set.looker.id}"

  storage_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "7.6"
    version   = "latest"
  }

  storage_os_disk {
    name          = "lookerapp-${count.index}-osdisk"
    vhd_uri       = "${azurerm_storage_account.looker.primary_blob_endpoint}${azurerm_storage_container.looker.name}/lookerapp-${count.index}-osdisk.vhd"
    caching       = "ReadWrite"
    create_option = "FromImage"
  }

  os_profile {
    computer_name  = "lookerapp${count.index}"
    admin_username = "root_looker"
    admin_password = "looker"
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      key_data = "${file("~/.ssh/id_rsa.pub")}" # this file must be an existing public key!
      path = "/home/root_looker/.ssh/authorized_keys"
    }
  }

  connection {
    host = "cluster-${random_id.id.hex}-${count.index}.${azurerm_resource_group.looker.location}.cloudapp.azure.com"
    user = "root_looker"
    type = "ssh"
    private_key = "${file("~/.ssh/id_rsa")}"
    timeout = "1m"
    agent = true
  }

   provisioner "remote-exec" {

    # Set up Looker!
    inline = [

      "sleep 10",

      # Install required packages
      "sudo yum update -y",
      "sudo yum install openssl-devel -y",
      "sudo yum install cifs-utils -y",
      "sudo yum install java-1.8.0-openjdk.x86_64 -y",

      # jq is not in yum
      "curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -O",
      "chmod +x jq-linux64",
      "sudo mv jq-linux64 /usr/local/bin/jq",

      # Chrome:
      "sudo yum groupinstall 'Fonts' -y",
      "echo \"[google-chrome]\" | sudo tee -a /etc/yum.repos.d/google-chrome.repo",
      "echo \"name=google-chrome\" | sudo tee -a /etc/yum.repos.d/google-chrome.repo",
      "echo \"baseurl=http://dl.google.com/linux/chrome/rpm/stable/x86_64\" | sudo tee -a /etc/yum.repos.d/google-chrome.repo",
      "echo \"enabled=1\" | sudo tee -a /etc/yum.repos.d/google-chrome.repo",
      "echo \"gpgcheck=1\" | sudo tee -a /etc/yum.repos.d/google-chrome.repo",
      "echo \"gpgkey=https://dl.google.com/linux/linux_signing_key.pub\" | sudo tee -a /etc/yum.repos.d/google-chrome.repo",
      "sudo yum install google-chrome-stable -y",
      "sudo ln -s /usr/bin/google-chrome /usr/bin/chromium",

      # Configure some important environment settings
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

      # Download and install Looker
      "sudo -u looker curl -s -i -X POST -H 'Content-Type:application/json' -d '{\"lic\": \"${var.looker_license_key}\", \"email\": \"${var.technical_contact_email}\", \"latest\":\"latest\"}' https://apidownload.looker.com/download -o /home/looker/looker/response.txt",
      "sudo -u looker sed -i 1,9d /home/looker/looker/response.txt",
      "sudo -u looker chmod 777 /home/looker/looker/response.txt",
      "eula=$(sudo cat /home/looker/looker/response.txt | jq -r '.eulaMessage')",
      "if [[ \"$eula\" =~ .*EULA.* ]]; then echo \"Error! This script was unable to download the latest Looker JAR file because you have not accepted the EULA. Please go to https://download.looker.com/validate and fill in the form.\"; fi;",
      "url=$(sudo cat /home/looker/looker/response.txt | jq -r '.url')",
      "sudo -u looker rm /home/looker/looker/response.txt",
      "sudo -u looker curl $url -o /home/looker/looker/looker.jar",
      "sudo -u looker curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/looker -o /home/looker/looker/looker",
      "sudo -u looker chmod 0750 /home/looker/looker/looker",

      # Determine the IP address of this instance so that it can be registered in the cluster
      "export IP=$(/sbin/ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')",
      "export CMD=\"sudo sed -i 's/LOOKERARGS=\\\"\\\"/LOOKERARGS=\\\"-d \\/home\\/looker\\/looker\\/looker-db.yml --clustered -H $IP --shared-storage-dir \\/mnt\\/lookerfiles\\\"/' /home/looker/looker/looker\"",
      "echo $CMD",
      "echo $CMD | bash",

      # Create the database credentials file
      "echo \"host: cluster-${random_id.id.hex}-db.${azurerm_resource_group.looker.location}.cloudapp.azure.com\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"username: looker\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"password: ${random_string.looker_password.result}\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"database: looker\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"dialect: mysql\" | sudo tee -a /home/looker/looker/looker-db.yml",
      "echo \"port: 3306\" | sudo tee -a /home/looker/looker/looker-db.yml",

      # Mount the shared file system
      "sudo mkdir -p /mnt/lookerfiles",
      "echo \"//${azurerm_storage_account.looker.name}.file.core.windows.net/${azurerm_storage_share.looker.name} /mnt/lookerfiles cifs nofail,vers=3.0,username=${azurerm_storage_account.looker.name},password=${data.azurerm_storage_account.looker.primary_access_key},dir_mode=0777,file_mode=0777,serverino\" | sudo tee -a /etc/fstab",
      "sudo mount -a",

      # Since this is an example, disable RHEL's firewall completely and depend on the Azure firewall for simplicity
      "sudo systemctl stop firewalld",

      # Start Looker (but wait a while before starting additional nodes, because the first node needs to prepare the application database schema)
      "if [ ${count.index} -eq 0 ]; then sudo su - looker -c \"/bin/bash /home/looker/looker/looker start\"; else sleep 300 && sudo su - looker -c \"/bin/bash /home/looker/looker/looker start\"; fi",
      "echo \"su - looker -c \\\"/bin/bash /home/looker/looker/looker start\\\"\" | sudo tee -a /etc/rc.d/rc.local",
      "sudo chmod +x /etc/rc.d/rc.local",
      "sudo systemctl enable rc-local",
      "sudo systemctl start rc-local",
    ]
  }
}

output "Load_Balanced_Host" {
  value = "Started https://cluster-${random_id.id.hex}.${azurerm_resource_group.looker.location}.cloudapp.azure.com (you will need to wait a few minutes for the instance to become available and you need to accept the unsafe self-signed certificate)"
}

####################################################################################
## BEGIN WORKAROUND FOR "MICROSOFT AZURE DATABASE FOR MYSQL" AUTHENTICATION ISSUE ##
##                                                                                 #
## The following should be replaced with an azurerm_mysql_database resource as     #
## soon as possible. We do not want to manage a VM for the database server.        #
## This is necessary due to the "Handshake failed" error helltool returns when     #
## connecting to a managed Azure MySQL database, maybe because of the use of a     #
## fully-qualified username.                                                       #
##                                                                                 #
####################################################################################

# Create a public IP address for the DB instance (at least delete this afterwards)
resource "azurerm_public_ip" "lookerdb" {
  name                         = "PublicIPForDB"
  location                     = "${azurerm_resource_group.looker.location}"
  resource_group_name          = "${azurerm_resource_group.looker.name}"
  allocation_method            = "Static"
  domain_name_label            = "cluster-${random_id.id.hex}-db"
  idle_timeout_in_minutes      = 30
}

# Create a network interface for the DB instance
resource "azurerm_network_interface" "lookerdb" {
  name                = "lookerdbnic"
  location            = "${azurerm_resource_group.looker.location}"
  resource_group_name = "${azurerm_resource_group.looker.name}"

  ip_configuration {
    name                          = "lookeripconfigurationdb"
    subnet_id                     = "${azurerm_subnet.looker.id}"
    private_ip_address_allocation = "dynamic"
    public_ip_address_id          = "${azurerm_public_ip.lookerdb.id}"
  }
}

resource "azurerm_virtual_machine" "lookerdb" {
  depends_on                       = ["azurerm_availability_set.looker"]
  name                             = "lookerdb"
  location                         = "${azurerm_resource_group.looker.location}"
  resource_group_name              = "${azurerm_resource_group.looker.name}"
  network_interface_ids            = ["${azurerm_network_interface.lookerdb.id}"]
  vm_size                          = "${var.instance_type}"
  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true
  availability_set_id              = "${azurerm_availability_set.looker.id}"

  storage_image_reference {
    publisher = "RedHat"
    offer     = "RHEL"
    sku       = "7.6"
    version   = "latest"
  }

  storage_os_disk {
    name          = "lookerdb-osdisk"
    vhd_uri       = "${azurerm_storage_account.looker.primary_blob_endpoint}${azurerm_storage_container.looker.name}/lookerdb-osdisk.vhd"
    caching       = "ReadWrite"
    create_option = "FromImage"
  }

  os_profile {
    computer_name  = "lookerdb"
    admin_username = "root_looker"
    admin_password = "looker"
  }

  os_profile_linux_config {
    disable_password_authentication = true
    ssh_keys {
      key_data = "${file("~/.ssh/id_rsa.pub")}"
      path = "/home/root_looker/.ssh/authorized_keys"
    }
  }

  connection {
    host = "cluster-${random_id.id.hex}-db.${azurerm_resource_group.looker.location}.cloudapp.azure.com"
    user = "root_looker"
    type = "ssh"
    private_key = "${file("~/.ssh/id_rsa")}"
    timeout = "1m"
    agent = true
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum update -y",

      # Install MySQL and create the Looker application database
      "sudo yum install https://dev.mysql.com/get/mysql80-community-release-el7-3.noarch.rpm -y",
      "sudo yum --disablerepo=mysql80-community --enablerepo=mysql57-community install mysql-community-server -y",
      "echo \"bind-address=0.0.0.0\" | sudo tee -a /etc/my.cnf",
      "sudo systemctl restart mysqld",
      "sudo mysql -u root --connect-expired-password -p`grep \"A temporary password\" /var/log/mysqld.log | egrep -o 'root@localhost: (.*)' | sed 's/root@localhost: //'` -e \"ALTER USER 'root'@'localhost' IDENTIFIED BY '${random_string.root_password.result}';\"",
      "sudo mysql -u root -p\"${random_string.root_password.result}\" -e \"CREATE USER 'looker' IDENTIFIED BY '${random_string.looker_password.result}'; CREATE DATABASE looker DEFAULT CHARACTER SET utf8 DEFAULT COLLATE utf8_general_ci; GRANT ALL ON looker.* TO looker@'%'; GRANT ALL ON looker_tmp.* TO 'looker'@'%'; FLUSH PRIVILEGES;\"",

      # Since this is an example, disable RHEL's firewall completely and depend on the Azure firewall for simplicity
      "sudo systemctl stop firewalld",
    ]
  }
}

# Generate a random database password
resource "random_string" "root_password" {
  length = 16
  special = true
  number = true
  min_numeric = 1
  min_special = 1
  min_upper = 1
}
resource "random_string" "looker_password" {
  length = 16
  special = true
  number = true
  min_numeric = 1
  min_special = 1
  min_upper = 1
}
