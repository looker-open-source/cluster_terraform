#!/bin/bash
# Looker setup script for RHEL6 - application server on Azure

# Install required packages
sudo yum update -y
sudo yum install openssl-devel -y
sudo yum install java-1.8.0-openjdk.x86_64 -y

# jq is not in yum
curl -L https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 -O
chmod +x jq-linux64
sudo mv jq-linux64 /usr/local/bin/jq

# Chromium dependencies:
sudo yum groupinstall 'Fonts' -y
sudo yum install mesa-libGL mesa-libEGL -y
sudo yum install dbus-x11 -y
sudo yum install chromium-browser.x86_64 -y

# This is one of the strangest hacks I've ever needed to make. Because chromium-browser --version was returning
# the line "a11y dbus service is already running!" before the Chrome version number, helltool incorrectly
# detected the Chromium version number as 11, instead of 75.
#   (see https://github.com/looker/helltool/blob/ea8c781180a0a6e8d523f1067bf2c54efcdef2bf/jvm-modules/chromium-renderer/src/main/kotlin/com/looker/render/ChromiumService.kt#L123)
# We can fix this by creating a Bash script that aliases chromium-browser as chromium (which is what helltool expects), and also cleans up the output.
cat <<EOT | sudo tee -a /usr/bin/chromium
#!/bin/bash
out=\`/usr/bin/chromium-browser "\$@"\`
echo \$out | sed "s/a11y dbus service is already running! //"
EOT
# This three-line script removes the problematic message from the "chromium-browser --version" output so helltool doesn't get confused:
sudo chmod +x /usr/bin/chromium

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

# The looker-dependencies.jar file will start being provided on 2019-09-01 for Looker 6.18
url=$(sudo cat /home/looker/looker/response.txt | jq -r '.depUrl')
sudo curl $url -o /home/looker/looker/looker-dependencies.jar

sudo curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/looker -O
sudo chmod 0750 looker

# Determine the IP address of this instance so that it can be registered in the cluster
export IP=$(sudo ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')
echo "LOOKERARGS=\"--no-daemonize -d /home/looker/looker/looker-db.yml --clustered -H $IP --shared-storage-dir /mnt/lookerfiles\"" >> /home/looker/looker/lookerstart.cfg

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

# Since this is an example, disable RHEL's firewall completely and depend on the Azure firewall for simplicity
sudo service iptables stop
sudo service iptables disable

# Azure Storage does not support RHEL6 so we need to use NFS and put a share on the database server
echo "lookerdb:/mnt/lookerfiles /mnt/lookerfiles nfs" | sudo tee -a /etc/fstab
sudo mount -a

# Create a sysvinit script to start Looker automatically
cat <<EOT | sudo tee -a /etc/init.d/looker
#!/bin/sh
# chkconfig: 345 70 30

case "\$1" in
      start)
       echo "Starting Looker wrapper"
       su - looker -c "/bin/bash /home/looker/looker/looker start > /dev/null 2>&1 &"
        ;;

      stop)
       pkill -u looker
       sudo rm /home/looker/looker/.starting
       echo "Looker wrapper is shutting down"
        ;;
         *)

       echo $"Usage: -bash {start|stop}"
       exit 5
esac
exit \$?
EOT

sudo chmod +x /etc/init.d/looker
sudo chkconfig --add looker
# Start Looker (but wait a while before starting additional nodes, because the first node needs to prepare the application database schema)
if [ $NODE_COUNT -eq 0 ]; then sudo service looker start; else sleep 300 && sudo service looker start; fi