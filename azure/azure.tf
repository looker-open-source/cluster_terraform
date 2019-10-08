provider azurerm {
  version = "~> 1.27.0"
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

# Create the virtual machines themselves!
resource "azurerm_virtual_machine" "looker" {

  # TODO: replace the azurerm_virtual_machine dependency with azurerm_mysql_database
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
    publisher = "${var.os_publisher}"
    offer     = "${var.os_offer}"
    sku       = "${var.os_sku}"
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

  provisioner "file" {
    source      = "${var.provisioning_script}/setup-${var.provisioning_script}.sh"
    destination = "/tmp/setup-${var.provisioning_script}.sh"
  }

  provisioner "remote-exec" {

    # Set up Looker!
    inline = [
      "sleep 10",

      "export LOOKER_LICENSE_KEY=${var.looker_license_key}",
      "export LOOKER_TECHNICAL_CONTACT_EMAIL=${var.technical_contact_email}",
      "export SHARED_STORAGE_SERVER=${azurerm_storage_account.looker.name}.file.core.windows.net/${azurerm_storage_share.looker.name}",
      "export DB_SERVER=cluster-${random_id.id.hex}-db.${azurerm_resource_group.looker.location}.cloudapp.azure.com",
      "export DB_USER=looker",
      "export DB_LOOKER_PASSWORD=\"${random_string.looker_password.result}\"",
      "export NODE_COUNT=${count.index}",
      "export FSTAB_ENTRY=\"//${azurerm_storage_account.looker.name}.file.core.windows.net/${azurerm_storage_share.looker.name} /mnt/lookerfiles cifs nofail,vers=3.0,username=${azurerm_storage_account.looker.name},password=${data.azurerm_storage_account.looker.primary_access_key},dir_mode=0777,file_mode=0777,serverino\"",

      "chmod +x /tmp/setup-${var.provisioning_script}.sh",
      "/bin/bash /tmp/setup-${var.provisioning_script}.sh",
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
    publisher = "${var.os_publisher}"
    offer     = "${var.os_offer}"
    sku       = "${var.os_sku}"
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
    agent = true // must be false on some platforms (Windows?)
  }

  provisioner "file" {
    source      = "${var.provisioning_script}/setup-${var.provisioning_script}-db.sh"
    destination = "/tmp/setup-${var.provisioning_script}-db.sh"
  }
  provisioner "remote-exec" {
    inline = [
      "sleep 10",

      "export DB_ROOT_PASSWORD=\"${random_string.root_password.result}\"",
      "export DB_LOOKER_PASSWORD=\"${random_string.looker_password.result}\"",

      "chmod +x /tmp/setup-${var.provisioning_script}-db.sh",
      "/bin/bash /tmp/setup-${var.provisioning_script}-db.sh",
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
  override_special = "#%^&*()-="
}
resource "random_string" "looker_password" {
  length = 16
  special = true
  number = true
  min_numeric = 1
  min_special = 1
  min_upper = 1
  override_special = "#%^&*()-="
}