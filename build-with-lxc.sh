#! /bin/bash

set -e
set -x

export TERM="xterm-256color"

###' Global variables

LXCPATH=/srv/lxc
OUTPUTPATH=/srv/olinux

# Debian distribution
DEBIAN_RELEASE=stretch
INSTALL_YUNOHOST_DIST='stable'

# Name of the master LXC container. Something like yunostretch or yunojessie
LXCMASTER_NAME=yuno${DEBIAN_RELEASE}
LXCMASTER_ROOTFS=${LXCPATH}/${LXCMASTER_NAME}/rootfs

# Human-readable log of the build process
YUNOHOST_LOG=/tmp/yunobuild.log

LXC_BRIDGE="ynhbuildbr0"
LXC_SUBNET="10.44.0"

# Name of the temporary container
CONT=tmp-${LXCMASTER_NAME}-$(date +%Y%m%d-%H%M)
CONT_ROOTFS=${LXCPATH}/${CONT}/rootfs

# APT command
APT='DEBIAN_FRONTEND=noninteractive apt install -y --assume-yes --no-install-recommends'

###.
###' Main function

function main() {
  check_prerequisites    || die "Missing pre-requisites"
  spawn_temp_lxc         || die "Failed to create temporary LXC container."
  configure_cube         || die "Failed to configure the InternetCube system."
  yunohost_install       || die "Failed to install basic yunohost over Debian."
  #yunohost_post_install  || die "Failed to execute yunohost post-install."
  create_images          || die "Failed to create images"
  destroy_temp_lxc       || die "Failed to destroy the temporary LXC container"
}

###.
###' Create a master container

# Execute a command inside the container
function _lxc_exec() {
  LC_ALL=C LANGUAGE=C LANG=C lxc-attach -P ${LXCPATH} -n ${CONT} -- /bin/bash -c "$1"
}

function build_lxc_master_if_needed() {
  mkdir -p "${LXCPATH}"
  if ! lxc-ls -P ${LXCPATH} -1 | grep "^${LXCMASTER_NAME}$"
  then
    # If btrfs is available, use it as a fast-cloning backend for LXC.
    fstype=$(df --output=fstype "${LXCPATH}" | tail -n 1)
    if [ "$fstype" != "btrfs" ]; then
      fstype="dir"
    fi
    LC_ALL=C sudo lxc-create -P $LXCPATH -B $fstype -n $LXCMASTER_NAME -t debian -- -r $DEBIAN_RELEASE
    sed -i "s/^lxc.network.type.*$/lxc.network.type = veth\nlxc.network.flags = up\nlxc.network.link = $LXC_BRIDGE\nlxc.network.name = eth0\nlxc.network.hwaddr = 00:FF:AA:BB:CC:01/" ${LXCPATH}/${LXCMASTER_NAME}/config

    # Configure debian apt repository
    cat <<EOT > $LXCMASTER_ROOTFS/etc/apt/sources.list
deb http://ftp.fr.debian.org/debian $DEBIAN_RELEASE main contrib non-free
deb http://security.debian.org/ $DEBIAN_RELEASE/updates main contrib non-free
EOT
    cat <<EOT > $LXCMASTER_ROOTFS/etc/apt/apt.conf.d/71-no-recommends
APT::Install-Suggests "0";
// We're too shy to disable recommends globally in yunohost
// because apps packagers probably rely on recommended packages
// being automatically installed.
//APT::Install-Recommends "0";
EOT

    if [ ${APTCACHER} ] ; then
      cat <<EOT > $LXCMASTER_ROOTFS/etc/apt/apt.conf.d/01proxy
Acquire::http::Proxy "http://${APTCACHER}:3142";
EOT
    fi

    sudo lxc-start -P $LXCPATH -n $LXCMASTER_NAME
    sleep 5
    LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- apt-get update
#    echo set locales/locales_to_be_generated en_US.UTF-8 | debconf-communicate
#    echo set locales/default_environment_locale en_US.UTF-8 | debconf-communicate
    LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- locale-gen en_US.UTF-8
    LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- localedef -i en_US -f UTF-8 en_US.UTF-8
    # Let's install right now some packages that will be needed by yunohost install later
    DEBIAN_FRONTEND=noninteractive LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- apt -y --assume-yes --no-install-recommends install \
    apt-utils libtext-iconv-perl lsb-release whiptail apt-transport-https \
    ca-certificates openssh-server ntp parted locales vim-nox bash-completion wget \
    gnupg2 python3 curl 'php-fpm|php5-fpm'
    LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- apt -y --purge autoremove
    LC_ALL=C LANGUAGE=C LANG=C sudo lxc-attach -P ${LXCPATH} -n ${LXCMASTER_NAME} -- apt -y clean
    sudo lxc-stop -P $LXCPATH -n $LXCMASTER_NAME
  fi
}

function spawn_temp_lxc() {
  info "Spawning Temp LXC."

  build_lxc_master_if_needed
  sudo lxc-copy -P $LXCPATH -n $LXCMASTER_NAME -N $CONT
  sudo lxc-start -P $LXCPATH -n $CONT
  sleep 5 # Networking setup needs a few seconds
}

function destroy_temp_lxc() {
  sudo lxc-stop -P $LXCPATH -n $CONT
  sudo lxc-destroy -P $LXCPATH -n $CONT
}

function check_prerequisites() {
  info "Checking Prerequisites."

  if [ "$(id -u)" != "0" ]; then
    echo "This script must be run as root" 1>&2
    exit 1
  fi


  # We need to make sure that lxc-net will be able to create
  # a new network interface and that dnsmasq will be able to
  # listen on port 53
  if $(netstat -lptun | grep -q '0.0.0.0:53\b')
  then
    echo "Problem. Make sure that port 53 is not already used.
You probably should run this command first: systemctl stop dnsmasq.service" >&2
    netstat -lptun | grep :53
    exit 2
  fi
  cat <<EOF > /etc/default/lxc-net
USE_LXC_BRIDGE="true"
LXC_BRIDGE="${LXC_BRIDGE}"
LXC_ADDR="${LXC_SUBNET}.254"
LXC_NETMASK="255.255.255.0"
LXC_NETWORK="${LXC_SUBNET}.0/24"
LXC_DHCP_RANGE="${LXC_SUBNET}.10,${LXC_SUBNET}.99"
LXC_DHCP_MAX="50"
LXC_DHCP_CONFILE=""
LXC_DOMAIN="yunobuild.lan"

# Dirty hack by pitchum
LXC_IPV6_ARG="--all-servers"
EOF
  systemctl restart lxc-net

  # Some packages that will be needed at the end of the process
  bins=(dd parted mkfs.ext4 zerofree losetup tune2fs)
  for i in "${bins[@]}"; do
    if ! which "${i}" &> /dev/null; then
      echo >&2 "${i} command is required"
      exit 3
    fi
  done

}

###.
###' Configure Cube Scripts

function configure_dhcp() {
  # Use dhcp on boot
  cat <<EOT > $CONT_ROOTFS/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
  post-up ip a a fe80::42:babe/128 dev eth0

auto usb0
allow-hotplug usb0
iface usb0 inet dhcp
EOT
}

function configure_misc (){
  # flash media tunning
  if [ -f "$CONT_ROOTFS/etc/default/tmpfs" ]; then
    sed -e 's/#RAMTMP=no/RAMTMP=yes/g' -i $CONT_ROOTFS/etc/default/tmpfs
    sed -e 's/#RUN_SIZE=10%/RUN_SIZE=128M/g' -i $CONT_ROOTFS/etc/default/tmpfs
    sed -e 's/#LOCK_SIZE=/LOCK_SIZE=/g' -i $CONT_ROOTFS/etc/default/tmpfs
    sed -e 's/#SHM_SIZE=/SHM_SIZE=128M/g' -i $CONT_ROOTFS/etc/default/tmpfs
    sed -e 's/#TMP_SIZE=/TMP_SIZE=1G/g' -i $CONT_ROOTFS/etc/default/tmpfs
  fi

  # Generate locales
  sed -i "s/^# fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/" $CONT_ROOTFS/etc/locale.gen
  sed -i "s/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" $CONT_ROOTFS/etc/locale.gen
  _lxc_exec "locale-gen en_US.UTF-8"

  # Update timezone
  echo 'Europe/Paris' > $CONT_ROOTFS/etc/timezone
  _lxc_exec "dpkg-reconfigure -f noninteractive tzdata"

  # Add fstab for root
  _lxc_exec "echo '/dev/mmcblk0p1 / ext4  defaults    0   1' >> /etc/fstab"

  # Configure tty
  cat <<EOT > $CONT_ROOTFS/etc/init/ttyS0.conf
start on stopped rc RUNLEVEL=[2345]
stop on runlevel [!2345]

respawn
exec /sbin/getty --noclear 115200 ttyS0
EOT
  _lxc_exec 'cp /lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service'
  _lxc_exec 'sed -e s/"--keep-baud 115200,38400,9600"/"-L 115200"/g -i /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service'

  # Configure SSH
  _lxc_exec "sed -i 's/PermitRootLogin without-password/PermitRootLogin yes/' /etc/ssh/sshd_config"

  # Good right on some directories
  _lxc_exec 'chmod 1777 /tmp/'
  _lxc_exec 'chgrp mail /var/mail/'
  _lxc_exec 'chmod g+w /var/mail/'
  _lxc_exec 'chmod g+s /var/mail/'

  # Add firstrun and secondrun init script
  install -m 755 -o root -g root build/script/firstrun $CONT_ROOTFS/usr/local/bin/
  install -m 755 -o root -g root build/script/secondrun $CONT_ROOTFS/usr/local/bin/
  install -m 755 -o root -g root build/script/hypercube/hypercube.sh $CONT_ROOTFS/usr/local/bin/
  install -m 444 -o root -g root build/script/firstrun.service $CONT_ROOTFS/etc/systemd/system/
  install -m 444 -o root -g root build/script/secondrun.service $CONT_ROOTFS/etc/systemd/system/
  install -m 444 -o root -g root build/script/hypercube/hypercube.service $CONT_ROOTFS/etc/systemd/system/
  _lxc_exec "/bin/systemctl daemon-reload >> /dev/null"
  _lxc_exec "/bin/systemctl enable firstrun >> /dev/null"
  _lxc_exec "/bin/systemctl enable hypercube >> /dev/null"

  # Add hypercube scripts
  mkdir -p $CONT_ROOTFS/var/log/hypercube
  install -m 444 -o root -g root build/script/hypercube/install.html $CONT_ROOTFS/var/log/hypercube/

  # Upgrade Packages
  _lxc_exec 'apt-get update'
  _lxc_exec 'apt-get upgrade -y --force-yes'
}

function configure_cube(){
  info "Configuring Cube"

  configure_dhcp        || die "Failed to configure DHCP."
  configure_misc        || die "Failed to configure misc configurations."
}

###.
###' Yunohost install & post-install

function yunohost_install() {
  info "Installing Yunohost."
  _lxc_exec "touch /var/log/auth.log" # Workaround for fail2ban postinstall failure when auth.log is missing
  _lxc_exec "apt -y install fail2ban"
  _lxc_exec "wget -O /tmp/install_yunohost https://install.yunohost.org/${DEBIAN_RELEASE} && chmod +x /tmp/install_yunohost"
  _lxc_exec "cd /tmp/ && ./install_yunohost -a -d ${INSTALL_YUNOHOST_DIST}"
}
function yunohost_post_install() {
  info "Post-Installing Yunohost."
  _lxc_exec "yunohost tools postinstall -d foo.bar.labriqueinter.net -p yunohost --ignore-dyndns --debug"
  _lxc_exec "apt -y --purge autoremove"
  _lxc_exec "apt -y clean"
}

###.
###' Create ISO images

function _create_image_with_encrypted_fs() {
  BOARD="${1}"
  . ./build/config_board.sh
  echo $FLASH_KERNEL > ${CONT_ROOTFS}/etc/flash-kernel/machine
  _lxc_exec 'update-initramfs -u -k all'
  ./build/create_device.sh -D img -s 2500 \
   -t ${OUTPUTPATH}/labriqueinternet_${FILE}_encryptedfs_"$(date '+%Y-%m-%d')"_${DEBIAN_RELEASE}${INSTALL_YUNOHOST_TESTING}.img \
   -d ${CONT_ROOTFS} \
   -b $BOARD

  pushd ${OUTPUTPATH}/
  tar czf labriqueinternet_${FILE}_encryptedfs_"$(date '+%Y-%m-%d')"_${DEBIAN_RELEASE}${INSTALL_YUNOHOST_TESTING}.img{.tar.xz,}
  popd
}

function _create_standard_image() {
  BOARD="${1}"
  # Switch to unencrypted root
  echo 'LINUX_KERNEL_CMDLINE="console=tty0 hdmi.audio=EDID:0 disp.screen0_output_mode=EDID:1280x720p60 root=/dev/mmcblk0p1 rootwait sunxi_ve_mem_reserve=0 sunxi_g2d_mem_reserve=0 sunxi_no_mali_mem_reserve sunxi_fb_mem_reserve=0 panic=10 loglevel=6 consoleblank=0"' >  ${CONT_ROOTFS}/etc/default/flash-kernel
  rm -f ${CONT_ROOTFS}/etc/crypttab
  echo '/dev/mmcblk0p1      /     ext4    defaults        0       1' > ${CONT_ROOTFS}/etc/fstab

  . ./build/config_board.sh
  mkdir -p ${CONT_ROOTFS}/etc/flash-kernel
  echo $FLASH_KERNEL > ${CONT_ROOTFS}/etc/flash-kernel/machine

  # install boot files and tools
  _lxc_exec "DEBIAN_FRONTEND=noninteractive $APT linux-image-armmp flash-kernel u-boot-tools initramfs-tools"
  _lxc_exec "wget -P /tmp/ https://repo.labriqueinter.net/u-boot/u-boot-sunxi_latest_armhf.deb"
  _lxc_exec "dpkg -i /tmp/u-boot-sunxi_latest_armhf.deb"

  _lxc_exec 'update-initramfs -u -k all'
  ./build/create_device.sh -D img -s 2500 \
   -t ${OUTPUTPATH}/labriqueinternet_${FILE}_"$(date '+%Y-%m-%d')"_${DEBIAN_RELEASE}${INSTALL_YUNOHOST_TESTING}.img \
   -d ${CONT_ROOTFS} \
   -b $BOARD

  pushd ${OUTPUTPATH}/
  tar czf labriqueinternet_${FILE}_"$(date '+%Y-%m-%d')"_${DEBIAN_RELEASE}${INSTALL_YUNOHOST_TESTING}.img{.tar.xz,}
  popd
}

function create_images() {
  mkdir -p ${OUTPUTPATH}
#  boardlist=( 'a20lime' 'a20lime2' )
  boardlist=( 'a20lime2' )
  for BOARD in ${boardlist[@]}
  do
    if test "z${BUILD_ENCRYPTED_IMAGES}" = "zyes"
    then
      _create_image_with_encrypted_fs "$BOARD"
    fi
    _create_standard_image "$BOARD"
  done
}

###.
###' HELPERS

readonly normal=$(printf '\033[0m')
readonly bold=$(printf '\033[1m')
readonly faint=$(printf '\033[2m')
readonly underline=$(printf '\033[4m')
readonly negative=$(printf '\033[7m')
readonly red=$(printf '\033[31m')
readonly green=$(printf '\033[32m')
readonly orange=$(printf '\033[33m')
readonly blue=$(printf '\033[34m')
readonly yellow=$(printf '\033[93m')
readonly white=$(printf '\033[39m')

function log()
{
  local level=${1}
  local msg=${2}
  printf "%-5s [$(date '+%Y-%m-%d %H:%M:%S')] %s\n" "${level}" "${msg}" >> ${YUNOHOST_LOG}
  if [ "OK" = "${level}" ]; then
    echo "[${bold}${green} ${level} ${normal}] ${msg}"
  elif [ "INFO" = "${level}" ]; then
    echo "[${bold}${blue}${level}${normal}] ${msg}"
  elif [ "WARN" = "${level}" ]; then
    echo "[${bold}${orange}${level}${normal}] ${msg}"
  elif [ "FAIL" = "${level}" -o "ERROR" = "${level}" ]; then
    echo "[${bold}${red}${level}${normal}] ${msg}"
  fi
}

function success()
{
  local msg=${1}
  log "OK" "${msg}"
}

function info()
{
  local msg=${1}
  log "INFO" "${msg}"
}

function warn()
{
  local msg=${1}
  log "WARN" "${msg}"
}

function error()
{
  local msg=${1}
  log "ERROR" "${msg}"
}

function die() {
    error "$1"
    info "Installation logs are available in $YUNOHOST_LOG"
    exit 1
}

###.

# Launch the build process
main "$@"

# vim: foldmethod=marker foldmarker=###',###.