#!/bin/bash

sudo apt-get update -y
sudo apt-get install libssl-dev -y
sudo apt-get install cifs-utils -y
sudo apt-get install fonts-freefont-otf -y
sudo apt-get install chromium-browser -y
sudo apt-get install openjdk-8-jdk -y
sudo apt-get install jq -y

# Install the Looker startup script
curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/systemd/looker.service -O
export CMD="sed -i 's/TimeoutStartSec=500/Environment=CHROMIUM_PATH=\\/usr\\/bin\\/chromium-browser/' looker.service"
echo $CMD | bash
sudo mv looker.service /etc/systemd/system/looker.service
sudo chmod 664 /etc/systemd/system/looker.service

# Configure some important environment settings
echo "net.ipv4.tcp_keepalive_time=200" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_intvl=200" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_keepalive_probes=5" | sudo tee -a /etc/sysctl.conf
echo "looker     soft     nofile     4096" | sudo tee -a /etc/security/limits.conf
echo "looker     hard     nofile     4096" | sudo tee -a /etc/security/limits.conf

# Configure user and group permissions
sudo groupadd looker
sudo useradd -m -g looker looker
sudo mkdir /home/looker/looker
sudo chown looker:looker /home/looker/looker
cd /home/looker/looker

# Download and install Looker
sudo curl -s -i -X POST -H 'Content-Type:application/json' -d '{"lic": "TODO-REPLACE-WITH-LICENSE-KEY", "email": "TODO-REPLACE-WITH-TECH-CONTACT", "latest":"latest"}' https://apidownload.looker.com/download -o /home/looker/looker/response.txt
sudo sed -i 1,9d response.txt
sudo chmod 777 response.txt
eula=$(cat response.txt | jq -r '.eulaMessage')
if [[ "$eula" =~ .*EULA.* ]]; then echo "Error! This script was unable to download the latest Looker JAR file because you have not accepted the EULA. Please go to https://download.looker.com/validate and fill in the form."; fi;
url=$(cat response.txt | jq -r '.url')
sudo rm response.txt
sudo curl $url -o /home/looker/looker/looker.jar
sudo chown looker:looker looker.jar
sudo curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/looker -O
sudo chmod 0750 looker
sudo chown looker:looker looker

# Determine the IP address of this instance so that it can be registered in the cluster
export IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')
export CMD="sudo sed -i 's/LOOKERARGS=\\"\\"/LOOKERARGS=\\"--no-daemonize -d \\/home\\/looker\\/looker\\/looker-db.yml --clustered -H $IP --shared-storage-dir \\/mnt\\/lookerfiles\\"/' /home/looker/looker/looker"
echo $CMD | bash

# Create the database credentials file
echo "host: TODO" | sudo tee -a /home/looker/looker/looker-db.yml
echo "username: TODO" | sudo tee -a /home/looker/looker/looker-db.yml
echo "password: TODO" | sudo tee -a /home/looker/looker/looker-db.yml
echo "database: TODO" | sudo tee -a /home/looker/looker/looker-db.yml
echo "dialect: mysql" | sudo tee -a /home/looker/looker/looker-db.yml
echo "port: TODO" | sudo tee -a /home/looker/looker/looker-db.yml

# Mount the shared file system
sudo mkdir -p /mnt/lookerfiles
sudo mount -t cifs //TODO /mnt/lookerfiles -o vers=3.0,username=TODO,password=TODO,dir_mode=0777,file_mode=0777,serverino

# Start Looker (but wait a while before starting additional nodes, because the first node needs to prepare the application database schema)
sudo systemctl daemon-reload
sudo systemctl enable looker.service
