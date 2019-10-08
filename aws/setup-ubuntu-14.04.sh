#!/bin/bash
# Looker setup script for Ubuntu 14.04 Trusty on AWS

# Install required packages
sudo add-apt-repository ppa:openjdk-r/ppa -y
sudo apt-get update -y
sudo apt-get install libssl-dev -y
sudo apt-get install cifs-utils -y
sudo apt-get install fonts-freefont-otf -y
sudo apt-get install chromium-browser -y
sudo ln -s /usr/bin/chromium-browser /usr/bin/chromium
sudo apt-get install openjdk-8-jdk -y
sudo apt-get install nfs-common -y
sudo apt-get install jq -y
      
# Uncomment the following line if connecting to AWS Redshift:
#"sudo ip link set dev eth0 mtu 1500

# Configure some impoortant environment settings
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
sudo chown looker:looker /home/looker/looker
cd /home/looker/looker

# Download and install Looker
sudo curl -s -i -X POST -H 'Content-Type:application/json' -d "{\"lic\": \"$LOOKER_LICENSE_KEY\", \"email\": \"$LOOKER_TECHNICAL_CONTACT_EMAIL\", \"latest\":\"latest\"}" https://apidownload.looker.com/download -o /home/looker/looker/response.txt
sudo sed -i 1,9d response.txt
sudo chmod 777 response.txt
eula=$(cat response.txt | jq -r '.eulaMessage')
if [[ "$eula" =~ .*EULA.* ]]; then echo "Error! This script was unable to download the latest Looker JAR file because you have not accepted the EULA. Please go to https://download.looker.com/validate and fill in the form."; fi;
url=$(cat response.txt | jq -r '.url')
sudo curl $url -o /home/looker/looker/looker.jar

url=$(cat response.txt | jq -r '.depUrl')
sudo curl $url -o /home/looker/looker/looker-dependencies.jar

# TODO: check SHA hash against the API response with shasum -a 256 looker-latest.jar

# Looker won't automatically create the deploy_keys directory
sudo mkdir /home/looker/looker/deploy_keys

sudo chown looker:looker looker.jar looker-dependencies.jar
sudo curl https://raw.githubusercontent.com/looker/customer-scripts/master/startup_scripts/looker -O
sudo chmod 0750 looker

# Determine the IP address of this instance so that it can be registered in the cluster
export IP=$(ip addr | grep 'state UP' -A2 | tail -n1 | awk '{print $2}' | cut -f1  -d'/')
echo "LOOKERARGS=\"--no-daemonize -d /home/looker/looker/looker-db.yml --clustered -H $IP --shared-storage-dir /mnt/lookerfiles\"" | sudo tee -a /home/looker/looker/lookerstart.cfg

sudo chown looker:looker looker

# Create the database credentials file
cat <<EOT | sudo tee -a /home/looker/looker/looker-db.yml
host: $DB_SERVER
username: $DB_USER
password: $DB_PASSWORD
database: $DB_USER
dialect: mysql
port: 3306
EOT

# Create mount point for the shared file system
sudo mkdir -p /mnt/lookerfiles
echo "$SHARED_STORAGE_SERVER:/ /mnt/lookerfiles nfs nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,noresvport" | sudo tee -a /etc/fstab
sudo mount -a
sudo chown looker:looker /mnt/lookerfiles
cat /proc/mounts | grep looker

# Create an Upstart script to start Looker automatically
cat <<EOT | sudo tee -a /etc/init.d/looker
#!/bin/sh
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
if [ $NODE_COUNT -eq 0 ]; then sudo service looker start; else sleep 300 && sudo service looker start; fi