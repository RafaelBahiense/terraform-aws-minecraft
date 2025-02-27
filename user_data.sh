#!/bin/bash -vx
#
# Install, configure and start a new Minecraft server
# This supports Ubuntu and Amazon Linux 2 flavors of Linux (maybe/probably others but not tested).

set -e

# Determine linux distro
if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS=$NAME
    VER=$VERSION_ID
elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si)
    VER=$(lsb_release -sr)
elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS=$DISTRIB_ID
    VER=$DISTRIB_RELEASE
elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    OS=Debian
    VER=$(cat /etc/debian_version)
elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    ...
elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    ...
else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    VER=$(uname -r)
fi

# Update OS and install start script
ubuntu_linux_setup() {
  export SSH_USER="ubuntu"
  export DEBIAN_FRONTEND=noninteractive
  /usr/bin/apt-get update
  /usr/bin/apt-get -yq install -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" default-jre wget awscli jq
  /bin/cat <<"__UPG__" > /etc/apt/apt.conf.d/10periodic
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
__UPG__

  # Init script for starting, stopping
  cat <<INIT > /etc/init.d/minecraft
#!/bin/bash
### BEGIN INIT INFO
# Provides:          minecraft
# Required-Start:    $local_fs $network
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start/stop minecraft server
### END INIT INFO

start() {
  echo "Starting minecraft server from /home/minecraft..."
  start-stop-daemon --start --quiet  --pidfile ${mc_root}/minecraft.pid -m -b -c $SSH_USER -d ${mc_root} --exec /usr/bin/java -- -Xmx${java_mx_mem} -Xms${java_ms_mem} -jar $MINECRAFT_JAR nogui
}

stop() {
  echo "Stopping minecraft server..."
  start-stop-daemon --stop --pidfile ${mc_root}/minecraft.pid
}

case \$1 in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    stop
    sleep 5
    start
    ;;
esac
exit 0
INIT

  # Start up on reboot
  /bin/chmod +x /etc/init.d/minecraft
  /usr/sbin/update-rc.d minecraft defaults

}

# Update OS and install start script
amazon_linux_setup() {
    export SSH_USER="ec2-user"
    /usr/bin/yum install java-1.8.0 yum-cron wget awscli jq -y
    /bin/sed -i -e 's/update_cmd = default/update_cmd = security/'\
                -e 's/apply_updates = no/apply_updates = yes/'\
                -e 's/emit_via = stdio/emit_via = email/' /etc/yum/yum-cron.conf
    chkconfig yum-cron on
    service yum-cron start
    /usr/bin/yum upgrade -y

    cat <<SYSTEMD > /etc/systemd/system/minecraft.service
[Unit]
Description=Minecraft Server
After=network.target

[Service]
Type=simple
User=$SSH_USER
WorkingDirectory=${mc_root}
ExecStart=/usr/bin/java -Xmx${java_mx_mem} -Xms${java_ms_mem} -jar $MINECRAFT_JAR nogui
Restart=on-abort

[Install]
WantedBy=multi-user.target
SYSTEMD

  # Start on boot
  /usr/bin/systemctl enable minecraft

}

### Thanks to https://github.com/kenoir for pointing out that as of v15 (?) we have to
### use the Mojang version_manifest.json to find java download location
### See https://minecraft.gamepedia.com/Version_manifest.json
download_minecraft_server() {

  WGET=$(which wget)

  # version_manifest.json lists available MC versions
  $WGET -O ${mc_root}/version_manifest.json https://launchermeta.mojang.com/mc/game/version_manifest.json

  # Find latest version number if user wants that version (the default)
  if [[ "${mc_version}" == "latest" ]]; then
    MC_VERS=$(jq -r '.["latest"]["'"${mc_type}"'"]' ${mc_root}/version_manifest.json)
  fi

  # Index version_manifest.json by the version number and extract URL for the specific version manifest
  VERSIONS_URL=$(jq -r '.["versions"][] | select(.id == "'"$MC_VERS"'") | .url' ${mc_root}/version_manifest.json)
  # From specific version manifest extract the server JAR URL
  SERVER_URL=$(curl -s $VERSIONS_URL | jq -r '.downloads | .server | .url')
  # And finally download it to our local MC dir
  $WGET -O ${mc_root}/$MINECRAFT_JAR $SERVER_URL

}

download_paper_mc_server() {
  
    WGET=$(which wget)

    # version_manifest.json lists available PaperMC versions of minecraft server
    $WGET -O "${mc_root}"/version_manifest.json https://api.papermc.io/v2/projects/paper

    # print manifest to console
    cat "${mc_root}"/version_manifest.json

    # Find latest version number if user wants that version (the default)
    if [[ "${mc_version}" == "latest" ]]; then
      MC_VERS=$(jq -r '.versions[-1]' "${mc_root}"/version_manifest.json)
    else
      MC_VERS=$(jq -r '.versions[] | select(.versions == "'"$mc_version"'") | .version' "${mc_root}"/version_manifest.json)
    fi

    # Then overwrite version_manifest.json with MC_VERS
    echo "$MC_VERS" > "${mc_root}"/version_manifest.json

    # build_manifest.json lists available PaperMC builds of the version
    $WGET -O "${mc_root}"/build_manifest.json https://api.papermc.io/v2/projects/paper/versions/"$MC_VERS"

    if [[ "${paper_mc_build}" == "latest" ]]; then
      BUILD=$(jq -r '.builds[-1]' "${mc_root}"/build_manifest.json)
    else
      BUILD=$(jq -r '.builds[] | select(.builds == "'"$paper_mc_build"'") | .build' "${mc_root}"/build_manifest.json)
    fi

    # Then overwrite build_manifest.json with BUILD
    echo $BUILD > ${mc_root}/build_manifest.json
  
    # And finally download it to our local MC dir
    $WGET -O ${mc_root}/$MINECRAFT_JAR https://api.papermc.io/v2/projects/paper/versions/$MC_VERS/builds/$BUILD/downloads/paper-$MC_VERS-$BUILD.jar
}

create_and_setup_dynv6_updater() {
  # Create dynv6 updater script
  cat <<DYNV6 > ${mc_root}/dynv6-updater.sh
#!/bin/bash

HOSTNAME_DYNV6="****.dynv6.net"
TOKEN_DYNV6="****"

# Get current IP address from AWS
IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# Update dynv6.net with current IP address
echo "IPv4 adress has changed -> update ..."
curl -s "https://ipv4.dynv6.com/api/update?hostname=${hostname_dynv6}&token=${token_dynv6}&ipv4=$IP"
echo "---"


DYNV6
  
  /bin/chmod +x ${mc_root}/dynv6-updater.sh

  # Init script for starting, stopping
  cat <<INIT > /etc/init.d/dynv6-updater
#!/bin/bash
### BEGIN INIT INFO
# Provides:          dynv6-updater
# Required-Start:    $local_fs $network
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Start dynv6-updater
### END INIT INFO

start() {
  echo "Starting dynv6-updater..."
  start-stop-daemon --start --background --chdir ${mc_root} --exec ${mc_root}/dynv6-updater.sh
}

stop() {
}

case \$1 in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    start
    ;;
esac
exit 0
INIT

  /bin/chmod +x /etc/init.d/dynv6-updater
  /usr/sbin/update-rc.d dynv6-updater.sh defaults

}

MINECRAFT_JAR="minecraft_server.jar"
case $OS in
  Ubuntu*)
    ubuntu_linux_setup
    ;;
  Amazon*)
    amazon_linux_setup
    ;;
  *)
    echo "$PROG: unsupported OS $OS"
    exit 1
esac

# Create mc dir, sync S3 to it and download mc if not already there (from S3)
/bin/mkdir -p ${mc_root}
/usr/bin/aws s3 sync s3://${mc_bucket} ${mc_root}

# Download server if it doesn't exist on S3 already (existing from previous install)
# To force a new server version, remove the server JAR from S3 bucket
if [[ ! -e "${mc_root}/$MINECRAFT_JAR" ]]; then
  if [[ -z "${paper_mc_build}" ]]; then
    download_minecraft_server
  else
    download_paper_mc_server
  fi
fi

# Cron job to sync data to S3 every five mins
/bin/cat <<CRON > /etc/cron.d/minecraft
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:${mc_root}
*/${mc_backup_freq} * * * *  $SSH_USER  /usr/bin/aws s3 sync ${mc_root}  s3://${mc_bucket}
CRON

# Update minecraft EULA
/bin/cat >${mc_root}/eula.txt<<EULA
#By changing the setting below to TRUE you are indicating your agreement to our EULA (https://account.mojang.com/documents/minecraft_eula).
#Tue Jan 27 21:40:00 UTC 2015
eula=true
EULA

# Create dynv6 updater script if dynv6.net hostname and token are provided
if [[ -n "${hostname_dynv6}" ]] && [[ -n "${token_dynv6}" ]]; then
  create_and_setup_dynv6_updater
fi

# Dirty fix
/bin/touch ${mc_root}/minecraft.pid
/bin/chown $SSH_USER ${mc_root}/minecraft.pid
/bin/chmod 664 ${mc_root}/minecraft.pid
/bin/chgrp $SSH_USER ${mc_root}/minecraft.pid

# Not root
/bin/chown -R $SSH_USER ${mc_root}

# Start the server
case $OS in
  Ubuntu*)
    /etc/init.d/minecraft start
    ;;
  Amazon*)
    /usr/bin/systemctl start minecraft
    ;;
esac

exit 0

