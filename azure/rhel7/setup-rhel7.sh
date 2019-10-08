#!/bin/bash
# Looker setup script for RHEL7 - application server on Azure

# Install required packages
sudo yum update -y
sudo yum install openssl-devel -y
sudo yum install cifs-utils -y
sudo yum install java-1.8.0-openjdk.x86_64 -y
sudo yum groupinstall 'Fonts' -y
cat <<EOT | sudo tee -a /etc/yum.repos.d/google-chrome.repo
[google-chrome]
name=google-chrome
baseurl=http://dl.google.com/linux/chrome/rpm/stable/x86_64
enabled=1
gpgcheck=1
gpgkey=https://dl.google.com/linux/linux_signing_key.pub
EOT
sudo yum install google-chrome-stable -y
sudo ln -s /usr/bin/google-chrome /usr/bin/chromium

# jq is not in yum
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -O
chmod +x jq-linux64
sudo mv jq-linux64 /usr/local/bin/jq

# Configure some important environment settings
cat <<EOT | sudo tee -a /etc/sysctl.conf
net.ipv4.tcp_keepalive_time=200
net.ipv4.tcp_keepalive_intvl=200
net.ipv4.tcp_keepalive_probes=5
EOT

cat <<EOT | sudo tee -a /etc/security/limits.conf
looker     soft     nofile     4096
looker     hard     nofile     4096
EOT

# Configure user and group permissions
sudo groupadd looker
sudo useradd -m -g looker looker
sudo mkdir /home/looker/looker

# Download and install Looker
sudo curl -s -i -X POST -H 'Content-Type:application/json' -d "{\"lic\": \"$LOOKER_LICENSE_KEY\", \"email\": \"$LOOKER_TECHNICAL_CONTACT_EMAIL\", \"latest\":\"latest\"}" https://apidownload.looker.com/download -o /home/looker/looker/response.txt
sudo sed -i 1,9d /home/looker/looker/response.txt
eula=$(sudo cat /home/looker/looker/response.txt | jq -r '.eulaMessage')
if [[ "$eula" =~ .*EULA.* ]]; then echo "Error! This script was unable to download the latest Looker JAR file because you have not accepted the EULA. Please go to https://download.looker.com/validate and fill in the form."; fi;
url=$(sudo cat /home/looker/looker/response.txt | jq -r '.url')
sudo curl $url -o /home/looker/looker/looker.jar

url=$(sudo cat /home/looker/looker/response.txt | jq -r '.depUrl')
sudo curl $url -o /home/looker/looker/looker-dependencies.jar

# TODO: check SHA hash against the API response with shasum -a 256 looker-latest.jar

# Looker won't automatically create the deploy_keys directory
sudo mkdir /home/looker/looker/deploy_keys

sudo chown looker:looker looker.jar looker-dependencies.jar
sudo curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/looker -o /home/looker/looker/looker
sudo chmod 0750 /home/looker/looker/looker

# Determine the IP address of this instance so that it can be registered in the cluster
export IP=$(sudo ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')
echo "LOOKERARGS=\"--no-daemonize -d /home/looker/looker/looker-db.yml --clustered -H $IP --shared-storage-dir /mnt/lookerfiles\"" | sudo tee -a /home/looker/looker/lookerstart.cfg

sudo chown looker:looker looker

# Create the database credentials file
cat <<EOT | sudo tee -a /home/looker/looker/looker-db.yml
host: $DB_SERVER
username: $DB_USER
password: $DB_LOOKER_PASSWORD
database: $DB_USER
dialect: mysql
port: 3306
EOT

sudo chown looker:looker -R /home/looker/

# Mount the shared file system
sudo mkdir -p /mnt/lookerfiles
echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab
sudo mount -a

# Since this is an example, disable RHEL's firewall completely and depend on the Azure firewall for simplicity
sudo systemctl stop firewalld
sudo systemctl disable firewalld

echo "su - looker -c \"/bin/bash /home/looker/looker/looker start &\"" | sudo tee -a /etc/rc.d/rc.local
sudo chmod +x /etc/rc.d/rc.local
sudo systemctl enable rc-local
sudo systemctl start rc-local

# Start Looker (but wait a while before starting additional nodes, because the first node needs to prepare the application database schema)
if [ $NODE_COUNT -eq 0 ]; then sudo su - looker -c "/bin/bash /home/looker/looker/looker start &"; else sleep 300 && sudo su - looker -c "/bin/bash /home/looker/looker/looker start &"; fi