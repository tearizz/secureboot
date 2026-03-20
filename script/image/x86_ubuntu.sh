#!/bin/bash
set -e

# ======  Log Configuration  ====== #
COLOR_INFO='\033[0;32m'     # Green
COLOR_WARN='\033[1;33m'     # Yellow
COLOR_ERROR='\033[0;31m'    # Red
COLOR_TITLE='\033[0;35m'    # Pink
COLOR_RESET='\033[0m'       # White

log_info(){
    local line func file
    read line func file <<< "$(caller 0)"
    printf "${COLOR_INFO}[ERROR] [%s:%d] %s${COLOR_RESET}\n" "$file" "$line" "$*" >&2
}
log_warn(){
    local line func file
    read line func file <<< "$(caller 0)"
    printf "${COLOR_WARN}[ERROR] [%s:%d] %s${COLOR_RESET}\n" "$file" "$line" "$*" >&2
}
log_error(){
    local line func file
    read line func file <<< "$(caller 0)"
    printf "${COLOR_ERROR}[ERROR] [%s:%d] %s${COLOR_RESET}\n" "$file" "$line" "$*" >&2
    exit
}
log_title(){
    local line func file
    read line func file <<< "$(caller 0)"
    printf "${COLOR_TITLE}[ERROR] [%s:%d] %s${COLOR_RESET}\n" "$file" "$line" "$*" >&2
}
log_blank(){
  printf "${COLOR_RESET} %s\n" "$*" 
}

_current_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
_script_path=$(dirname "$_current_path")
_secureboot_path=$(dirname "$_script_path")
_artifact_path="$_secureboot_path/artifact"

# ======  Artifact Configuration  ====== #
DISK_NAME="$_artifact_path/image/x86_ubuntu.img"
KERNEL="$_artifact_path/kernel/vmlinuz-6.8.0-90-generic"
INITRD="$_artifact_path/kernel/initrd.img-6.8.0-90-generic"

SHIM="$_artifact_path/shim/shimx64.efi"
MMX="$_artifact_path/shim/mmx64.efi"
BOOTX64_CSV="$_artifact_path/shim/mmx64.efi"

# Use Same PrivKey and Cert which signed Shim and imported DB to Sign Grub
DB_PRIV_KEY="$_artifact_path/keys/DB.key"
DB_CERT="$_artifact_path/keys/DB.crt"
VENDOR_PRIV_KEY=$DB_PRIV_KEY
VENDOR_CERT=$DB_CERT

for file in "$KERNEL" "$INITRD" "$SHIM" "$MMX" "$BOOTX64_CSV" "$DB_PRIV_KEY" "$DB_CERT"; do
  if [ ! -f "$file" ]; then
    log_error "$file does not exist"
    exit 1
  fi
done
log_info "all required files are present"

# ======  Cleanup Trap  ====== #
LOOP=""
ESP_MOUNT=""
ROOT_MOUNT=""

cleanup() {
  log_warn "cleaning up loop device and mounts..."
  sudo umount "$ROOT_MOUNT/boot/efi" 2>/dev/null || true
  sudo umount "$ROOT_MOUNT/dev"      2>/dev/null || true
  sudo umount "$ROOT_MOUNT/proc"     2>/dev/null || true
  sudo umount "$ROOT_MOUNT/sys"      2>/dev/null || true
  sudo umount "$ESP_MOUNT"           2>/dev/null || true
  sudo umount "$ROOT_MOUNT"          2>/dev/null || true
  [ -n "$LOOP" ] && sudo losetup -d "$LOOP" 2>/dev/null || true
  sudo rm -rf "$ESP_MOUNT" "$ROOT_MOUNT"    2>/dev/null || true
}
trap cleanup EXIT


log_title "Create and part new disk"
rm -f "$DISK_NAME"
qemu-img create -f raw "$DISK_NAME" 12G

sudo parted -s "$DISK_NAME" \
  mklabel gpt \
  mkpart ESP fat32 1MiB 512MiB \
  set 1 esp on \
  mkpart primary ext4 512MiB 100%

# connect loop device
LOOP=$(sudo losetup -f -P "$DISK_NAME" --show)
log_info "new loop device: $LOOP"
sleep 2

# format partition
sudo mkfs.fat -F32 -n ESP "${LOOP}p1"
sudo mkfs.ext4 -F -L rootfs "${LOOP}p2"

# mount partition
ESP_MOUNT="/tmp/esp_fixed_$$"
ROOT_MOUNT="/tmp/root_fixed_$$"

#create and mount ESP/ROOT
mkdir -p "$ESP_MOUNT" "$ROOT_MOUNT"
sudo mount "${LOOP}p1" "$ESP_MOUNT"
sudo mount "${LOOP}p2" "$ROOT_MOUNT"
log_info "mounted esp: $ESP_MOUNT"
log_info "mounted root: $ROOT_MOUNT"

log_title "Install ubuntu root filesystem"
# install rootfs
sudo debootstrap --arch amd64 \
  --include=grub-common,grub2-common,grub-efi-amd64,grub-efi-amd64-bin \
  jammy "$ROOT_MOUNT" http://archive.ubuntu.com/ubuntu 
# Do not Verbose 
# jammy "$ROOT_MOUNT" http://archive.ubuntu.com/ubuntu > /dev/null

ROOT_UUID=$(sudo blkid -s UUID -o value "${LOOP}p2")
ESP_UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")
log_info "esp UUID: $ESP_UUID"
log_info "rtfs UUID: $ROOT_UUID"

sudo tee "$ROOT_MOUNT/etc/fstab" > /dev/null <<EOF
UUID=$ROOT_UUID /               ext4    defaults,errors=remount-ro 0       1
UUID=$ESP_UUID  /boot/efi       vfat    umask=0077,nofail 0       0
proc            /proc           proc    defaults        0       0
sysfs           /sys            sysfs   defaults        0       0
devtmpfs        /dev            devtmpfs defaults       0       0
tmpfs           /run            tmpfs   defaults        0       0
EOF

# config network
echo "grub-test" | sudo tee "$ROOT_MOUNT/etc/hostname" > /dev/null

sudo tee "$ROOT_MOUNT/etc/hosts" > /dev/null <<EOF
127.0.0.1   localhost
127.0.1.1   grub-test
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

# construct esp dir
sudo mkdir -p "$ESP_MOUNT/EFI/BOOT"
sudo mkdir -p "$ESP_MOUNT/EFI/ubuntu"
sudo mkdir -p "$ESP_MOUNT/grub"

# copy kernel and modules
KERNEL_VERSION=$(basename "$KERNEL" | sed 's/vmlinuz-//')
log_info "kernel version: $KERNEL_VERSION"
sudo cp "$KERNEL" "$ROOT_MOUNT/boot/"
sudo cp "$INITRD" "$ROOT_MOUNT/boot/"

sudo mkdir -p "$ROOT_MOUNT/boot/efi"
if [ -d "/lib/modules/$KERNEL_VERSION" ]; then
    sudo mkdir -p "$ROOT_MOUNT/lib/modules"
    sudo cp -r "/lib/modules/$KERNEL_VERSION" "$ROOT_MOUNT/lib/modules/"
else
  log_info "kernel modules are embed in grub"
fi

# copy shim, mmx, bootx64.csv
log_title "Migrate kernel and shim"
sudo cp "$SHIM" "$ESP_MOUNT/EFI/ubuntu/shimx64.efi"
sudo cp "$SHIM" "$ESP_MOUNT/EFI/BOOT/BOOTX64.efi"
sudo cp "$MMX" "$ESP_MOUNT/EFI/ubuntu/mmx64.efi"
sudo cp "$BOOTX64_CSV" "$ESP_MOUNT/EFI/ubuntu/BOOTX64.CSV"


# config and install grub
log_title "Install and config grub"
sudo tee "$ROOT_MOUNT/etc/default/grub" > /dev/null <<'EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_DISTRIBUTOR="Ubuntu"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="console=ttyS0,115200n8 debug loglevel=7 no-splash console=tty0 raid=noautodetect rw  lsm=lockdown lsm.debug lockdown=none"
GRUB_TERMINAL="console"
GRUB_DISABLE_OS_PROBER=true
GRUB_USE_LINUXEFI=true
EOF

sudo mount --bind /dev "$ROOT_MOUNT/dev"
sudo mount --bind /proc "$ROOT_MOUNT/proc"
sudo mount --bind /sys "$ROOT_MOUNT/sys"
sudo mount --bind "$ESP_MOUNT" "$ROOT_MOUNT/boot/efi"

sudo chroot "$ROOT_MOUNT" /bin/bash <<'CHROOT'
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C
export LANG=C

echo "root:password" | chpasswd

cat > /tmp/grub_sbat.csv << 'EOF'
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,3,Free Software Foundation,grub,2.06,https://www.gnu.org/software/grub/
grub.ubuntu,1,Ubuntu,grub2,2.06,https://packages.ubuntu.com/grub2
EOF

grub-mkimage \
  -o /boot/efi/EFI/ubuntu/grubx64.efi \
  --sbat /tmp/grub_sbat.csv \
  -O x86_64-efi \
  -p /boot/grub \
  part_gpt part_msdos fat ext2 normal \
  configfile linux search search_fs_uuid \
  search_label echo test cat ls loadenv \
  minicmd boot chain reboot halt gzio gfxterm \
  gfxmenu all_video video video_fb  \
  gettext true sleep linuxefi

grub-mkconfig -o /boot/grub/grub.cfg
if [ ! -f /boot/grub/grub.cfg ]; then
  echo "Fail to generate grub.cfg"
  exit 1 
fi

cat > /boot/grub/test << 'EOF'
test
EOF

if [ -f /boot/efi/EFI/ubuntu/grubx64.efi ]; then
  echo "success to install grub2"
 # ls -la /boot/efi/EFI/ubuntu/
else
  echo "fail to install grub2"
  exit 1
fi

if [ -f /boot/grub/grub.cfg ]; then
  echo "success to generate grub.cfg"
#  echo "Size of grub: $(stat -c%s /boot/grub/grub.cfg) bytes"
  
#  if grep -q "menuentry" /boot/grub/grub.cfg; then
#    cat /boot/grub/grub.cfg
#  else
#    echo "✗ Not found menuentry"
#  fi
#else
#  echo "✗ Fail to generate grub.cfg"
fi

apt-get install -y mokutil

exit
CHROOT

# migrate grub.cfg to esp
if [ -f "$ROOT_MOUNT/boot/grub/grub.cfg" ]; then
  # Ensure GRUB will find the config: put it under /boot/grub on the EFI filesystem
   sudo mkdir -p "$ESP_MOUNT/boot/grub"
   sudo cp "$ROOT_MOUNT/boot/grub/grub.cfg" "$ESP_MOUNT/boot/grub/"
  # migrate grub.cfg to $ESP_MOUNT/boot/grub/ and $ESP_MOUNT/grub/
  log_info "success to migrate grub.cfg"
else
  log_warn "not found: grub.cfg"
fi

# sign grub
log_title "Sign grub by OriginSign"
if ! command -v sbsign > /dev/null; then
  sudo apt-get update
  sudo apt-get install -y sbsigntool
fi

sbsign --key "$VENDOR_PRIV_KEY" --cert "$VENDOR_CERT" \
  --output "$ESP_MOUNT/EFI/ubuntu/grubx64.efi" "$ESP_MOUNT/EFI/ubuntu/grubx64.efi" 

sbverify --cert "$VENDOR_CERT" "$ESP_MOUNT/EFI/ubuntu/grubx64.efi"

log_info "copy grubx64.efi to /BOOT/"
if [ -f "$ESP_MOUNT/EFI/ubuntu/grubx64.efi" ]; then
  sudo cp "$ESP_MOUNT/EFI/ubuntu/grubx64.efi" "$ESP_MOUNT/EFI/BOOT/grubx64.efi"
else
  log_error "GRUB NOT FOUND"
fi

log_title "Check file structure"
log_info "esp："
find "$ESP_MOUNT" -type f | sort

echo ""
log_info "shim: $([ -f "$ESP_MOUNT/EFI/BOOT/BOOTX64.efi" ] && echo "✓" || echo "✗")"
log_info "grub (ubuntu): $([ -f "$ESP_MOUNT/EFI/ubuntu/grubx64.efi" ] && echo "✓" || echo "✗")"
log_info "grub (boot): $([ -f "$ESP_MOUNT/EFI/BOOT/grubx64.efi" ] && echo "✓" || echo "✗")"
# log_info "grub.cfg: $([ -f "$ESP_MOUNT/grub/grub.cfg" ] && echo "✓" || echo "✗")"
log_info "kernel: $([ -f "$ROOT_MOUNT/boot/vmlinuz-$KERNEL_VERSION" ] && echo "✓" || echo "✗")"
log_info "initramfs (root): $([ -f "$ROOT_MOUNT/boot/initrd.img-$KERNEL_VERSION" ] && echo "✓" || echo "✗")"

# echo ""
# if [ -d "$ESP_MOUNT/grub/x86_64-efi" ]; then
#     echo "✓ GRUB : $(ls "$ESP_MOUNT/grub/x86_64-efi" | wc -l) 个"
# else
#     echo "✗ GRUB 模块目录不存在"
# fi

log_info ""
# log_info "grub.cfg："
if [ -f "$ESP_MOUNT/grub/grub.cfg" ]; then
    log_info "$(stat -c%s "$ESP_MOUNT/grub/grub.cfg") bytes"
    log_info ""
    sudo grep "menuentry" "$ESP_MOUNT/grub/grub.cfg" | head -3 || echo_warn "not found menuentry"
    echo ""
    sudo grep "linux.*vmlinuz" "$ESP_MOUNT/grub/grub.cfg" | head -2 || echo_warn "not found kernel"
fi

# unmount
sudo umount "$ROOT_MOUNT/boot/efi" 2>/dev/null || true
sudo umount "$ROOT_MOUNT/dev" 2>/dev/null || true
sudo umount "$ROOT_MOUNT/proc" 2>/dev/null || true
sudo umount "$ROOT_MOUNT/sys" 2>/dev/null || true
sleep 2

sudo umount "$ESP_MOUNT" 2>/dev/null || {
    # uninstall $ESP_MOUNT
    sudo fuser -km "$ESP_MOUNT" 2>/dev/null || true
    sleep 1
    sudo umount -f "$ESP_MOUNT" || true
}

sudo umount "$ROOT_MOUNT" 2>/dev/null || {
    # uninstall $ROOT_MOUNT
    sudo fuser -km "$ROOT_MOUNT" 2>/dev/null || true
    sleep 1
    sudo umount -f "$ROOT_MOUNT" || true
}

sleep 1
sudo losetup -d "$LOOP"
sudo rm -rf "$ESP_MOUNT" "$ROOT_MOUNT" 2>/dev/null || true

log_title "Success to create disk image!"
