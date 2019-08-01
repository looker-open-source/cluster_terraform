#!/bin/bash
# Looker setup script for RHEL7 - database and shared storage server on Azure

sudo yum update -y

# Install MySQL and create the Looker application database
sudo yum install https://dev.mysql.com/get/mysql80-community-release-el7-3.noarch.rpm -y
sudo yum --disablerepo=mysql80-community --enablerepo=mysql57-community install mysql-community-server -y
echo "bind-address=0.0.0.0" | sudo tee -a /etc/my.cnf
sudo systemctl restart mysqld
sudo mysql -u root --connect-expired-password -p`sudo grep "A temporary password" /var/log/mysqld.log | egrep -o 'root@localhost: (.*)' | sed 's/root@localhost: //'` -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASSWORD';"
sudo mysql -u root -p"$DB_ROOT_PASSWORD" -e "CREATE USER 'looker' IDENTIFIED BY '$DB_LOOKER_PASSWORD'; CREATE DATABASE looker DEFAULT CHARACTER SET utf8 DEFAULT COLLATE utf8_general_ci; GRANT ALL ON looker.* TO looker@'%'; GRANT ALL ON looker_tmp.* TO 'looker'@'%'; FLUSH PRIVILEGES;"

# Since this is an example, disable RHEL's firewall completely and depend on the Azure firewall for simplicity
sudo systemctl stop firewalld
sudo systemctl disable firewalld