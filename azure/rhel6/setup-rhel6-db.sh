#!/bin/bash
# Looker setup script for RHEL6 - database and shared storage server on Azure

sudo yum update -y

# Install MySQL and create the Looker application database
sudo rpm -Uvh https://repo.mysql.com/mysql57-community-release-el6-9.noarch.rpm
sudo sed -i 's/enabled=1/enabled=0/' /etc/yum.repos.d/mysql-community.repo
sudo yum --enablerepo=mysql57-community install mysql-community-server -y
echo "bind-address=0.0.0.0" | sudo tee -a /etc/my.cnf
sudo service mysqld restart
sudo mysql -u root --connect-expired-password -p`sudo grep "A temporary password" /var/log/mysqld.log | egrep -o 'root@localhost: (.*)' | sed 's/root@localhost: //'` -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${random_string.root_password.result}';"
sudo mysql -u root -p"$DB_ROOT_PASSWORD" -e "CREATE USER 'looker' IDENTIFIED BY '$DB_LOOKER_PASSWORD'; CREATE DATABASE looker DEFAULT CHARACTER SET utf8 DEFAULT COLLATE utf8_general_ci; GRANT ALL ON looker.* TO looker@'%'; GRANT ALL ON looker_tmp.* TO 'looker'@'%'; FLUSH PRIVILEGES;"

# Since this is an example, disable RHEL's firewall completely and depend on the Azure firewall for simplicity
sudo service iptables stop
sudo service iptables disable

# Create a share that the application servers will mount
sudo /sbin/service nfs start
sudo chkconfig --add nfs
sudo mkdir -p /mnt/lookerfiles
sudo chmod 777 /mnt/lookerfiles
echo "/mnt *(rw,sync)" | sudo tee -a /etc/exports
sudo /usr/sbin/exportfs -a