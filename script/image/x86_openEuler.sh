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
    printf "${COLOR_INFO}[INFO] [%s:%d] %s${COLOR_RESET}\n" "$file" "$line" "$*" >&2
}
log_warn(){
    local line func file
    read line func file <<< "$(caller 0)"
    printf "${COLOR_WARN}[WARN] [%s:%d] %s${COLOR_RESET}\n" "$file" "$line" "$*" >&2
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
    printf "${COLOR_TITLE}[TITLE] [%s:%d] %s${COLOR_RESET}\n" "$file" "$line" "$*" >&2
}
log_blank(){
  printf "${COLOR_RESET} %s\n" "$*" 
}

_current_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
_script_path=$(dirname "$_current_path")
_secureboot_path=$(dirname "$_script_path")
_artifact_path="$_secureboot_path/artifact"

# ======  Artifact Configuration  ====== #
DISK_NAME="$_artifact_path/image/x86_openEuler.img"
# Install Kernel by dnf in OpenEuler container
SHIM="$_artifact_path/shim/shimx64.efi"
MMX="$_artifact_path/shim/mmx64.efi"
BOOTX64_CSV="$_artifact_path/shim/mmx64.efi"

# Use Same PrivKey and Cert which signed Shim and imported DB to Sign Grub
DB_PRIV_KEY="$_artifact_path/keys/DB.key"
DB_CERT="$_artifact_path/keys/DB.crt"
VENDOR_PRIV_KEY=$DB_PRIV_KEY
VENDOR_CERT=$DB_CERT


rm -f $DISK_NAME

for file in "$SHIM" "$MMX" "$BOOTX64_CSV" "$DB_PRIV_KEY" "$DB_CERT"; do
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

# create and mount ESP/ROOT
mkdir -p "$ESP_MOUNT" "$ROOT_MOUNT"
sudo mount "${LOOP}p1" "$ESP_MOUNT"
sudo mount "${LOOP}p2" "$ROOT_MOUNT"
log_info "mounted esp: $ESP_MOUNT"
log_info "mounted root: $ROOT_MOUNT"

# get UUID
ROOT_UUID=$(sudo blkid -s UUID -o value "${LOOP}p2")
ESP_UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")
log_info "esp UUID: $ESP_UUID"
log_info "rtfs UUID: $ROOT_UUID"

# construct esp dir
sudo mkdir -p "$ESP_MOUNT/EFI/BOOT"
sudo mkdir -p "$ESP_MOUNT/EFI/openEuler"
sudo mkdir -p "$ESP_MOUNT/grub"

# copy shim, mmx, bootx64.csv
log_title "Copy shim and related files to ESP"
log_blank
sudo cp "$SHIM" "$ESP_MOUNT/EFI/openEuler/shimx64.efi"
sudo cp "$SHIM" "$ESP_MOUNT/EFI/BOOT/BOOTX64.efi"
sudo cp "$MMX" "$ESP_MOUNT/EFI/openEuler/mmx64.efi"
sudo cp "$BOOTX64_CSV" "$ESP_MOUNT/EFI/openEuler/BOOTX64.CSV"

# ====== Install OpenEuler and Grub by Docker Container  ======
docker pull hub.oepkgs.net/openeuler/openeuler:24.03-lts

sudo docker run --privileged --rm \
  -e "ROOT_UUID=$ROOT_UUID" \
  -e "ESP_UUID=$ESP_UUID" \
  -v "$ROOT_MOUNT":/mnt/rootfs \
  -v "$ESP_MOUNT":/mnt/esp \
  hub.oepkgs.net/openeuler/openeuler:24.03-lts \
  /bin/bash -c "$(cat <<'INNER'
set -e
dnf install -y util-linux > /dev/null
echo "=== Installing base system using dnf ==="
dnf install -y --installroot=/mnt/rootfs \
  --releasever=24.03 \
  --repofrompath=openeuler,https://repo.openeuler.org/openEuler-24.03-LTS/OS/x86_64/ \
  bash coreutils systemd dnf kernel \
  grub2-efi-x64 efibootmgr grub2-efi-x64-modules \
  --nogpgcheck 

# copy DNS configuration
cp /etc/resolv.conf /mnt/rootfs/etc/

# mount virt filesystem
mount --bind /dev /mnt/rootfs/dev
mount --bind /proc /mnt/rootfs/proc
mount --bind /sys /mnt/rootfs/sys
mount --bind /mnt/esp /mnt/rootfs/boot/efi

echo "== Chrooting to configure system ==="
chroot /mnt/rootfs /bin/bash <<'CHROOT'
set -e

# create etc/fstab
cat > /etc/fstab <<EOF
UUID=$ROOT_UUID /               ext4    defaults,errors=remount-ro 0       1
UUID=$ESP_UUID  /boot/efi       vfat    umask=0077,nofail 0       0
proc            /proc           proc    defaults        0       0
sysfs           /sys            sysfs   defaults        0       0
devtmpfs        /dev            devtmpfs defaults       0       0
tmpfs           /run            tmpfs   defaults        0       0
EOF

# set hosts
echo "openeuler-test" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   openeuler-test
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

echo "root:password" | chpasswd

dnf install -y mokutil

# 配置 grub 默认参数（必须在 grub2-mkconfig 之前设置）：
# - console=ttyS0,115200n8：将内核输出重定向到串口，QEMU -nographic 模式下可见
# - GRUB_USE_LINUXEFI=true：Secure Boot 模式下必须用 linuxefi 指令加载内核
# - GRUB_TERMINAL=console：grub 菜单输出到控制台（串口可见）
cat > /etc/default/grub << 'GRUB_EOF'
GRUB_DEFAULT=0
GRUB_TIMEOUT=10
GRUB_DISTRIBUTOR="openEuler"
GRUB_CMDLINE_LINUX_DEFAULT=""
GRUB_CMDLINE_LINUX="rw console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_DISABLE_OS_PROBER=true
GRUB_USE_LINUXEFI=true
GRUB_EOF

cat > /tmp/grub_sbat.csv << 'SBAT_EOF'
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,3,Free Software Foundation,grub,2.12,https://www.gnu.org/software/grub/
grub.openeuler,1,openEuler,grub2,2.12,https://repo.openeuler.org
SBAT_EOF

grub2-mkimage \
  -o /boot/efi/EFI/openEuler/grubx64.efi \
  --sbat /tmp/grub_sbat.csv \
  -O x86_64-efi \
  -p /EFI/openEuler \
  part_gpt part_msdos fat ext2 normal \
  configfile linux search search_fs_uuid \
  search_label echo test cat ls loadenv \
  minicmd boot chain reboot halt gzio linuxefi

grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg

# grub2-mkconfig 在特权容器内 chroot 时，grub-probe 看到的根设备是宿主机的
# loop device（/dev/loop*），且 grub-probe --target=fs_uuid 在容器环境里
# 常常失败，导致 grub.cfg 里生成 root=/dev/loop20p2 而非 root=UUID=...。
# VM 启动后 systemd 从 /proc/cmdline 读到 root=/dev/loop20p2，等待该设备
# 出现（永远不会），造成卡住。此处统一替换为正确的 UUID。
sed -i "s|root=/dev/loop[0-9]*p[0-9]*|root=UUID=${ROOT_UUID}|g" \
    /boot/efi/EFI/openEuler/grub.cfg

cp /boot/efi/EFI/openEuler/grub.cfg /boot/grub2/grub.cfg

if [[ -f /boot/efi/EFI/openEuler/grubx64.efi ]]; then
  echo "GRUB installed successfully"
else
  echo "GRUB installed failed"
  exit 1
fi

CHROOT

# umount
umount /mnt/rootfs/dev
umount /mnt/rootfs/proc
umount /mnt/rootfs/sys
umount /mnt/rootfs/boot/efi

echo "=== Container tasks completed ==="
INNER
)"

# Finish Work in Container, Back to Host
log_title "Container finished, now signing shim and grub on host"
if ! command -v sbsign > /dev/null; then
  sudo apt-get update 
  sudo apt-get install -y sbsigntool
fi

# 复原预签名 shim（与 x86_ubuntu.sh 保持一致：shim 由 gen_inject_sign.sh 负责签名，
# 此处只需复原，不能重签——重签会追加第 N+1 个签名，与 ubuntu 实现不一致）。
# 同时防御性地重新拷贝，以防 grub2-install 意外覆盖了 EFI/BOOT/BOOTX64.efi。
log_title "Restore pre-signed shim to ESP"
sudo cp "$SHIM" "$ESP_MOUNT/EFI/BOOT/BOOTX64.efi"
sudo cp "$SHIM" "$ESP_MOUNT/EFI/openEuler/shimx64.efi"

sbverify --cert "$DB_CERT" "$ESP_MOUNT/EFI/BOOT/BOOTX64.efi"
log_info "Shim signature verified (pre-signed by gen_inject_sign.sh)"

# Sign Grub
GRUB_EFI="$ESP_MOUNT/EFI/openEuler/grubx64.efi"
if [ ! -f "$GRUB_EFI" ]; then
  log_error "grubx64.efi not found at $GRUB_EFI"
fi

sbsign --key "$VENDOR_PRIV_KEY" --cert "$VENDOR_CERT" \
  --output "$GRUB_EFI" "$GRUB_EFI"

sbverify --cert "$VENDOR_CERT" "$GRUB_EFI"

log_info "copy grubx64.efi to /BOOT"
sudo cp "$GRUB_EFI" "$ESP_MOUNT/EFI/BOOT/grubx64.efi"

# Check file structure
log_title "Check file structure"
log_warn "ESP_MOUNT='$ESP_MOUNT'" >&2
find "$ESP_MOUNT" -type f | sort

echo ""
log_info "shim (BOOT): $([ -f "$ESP_MOUNT/EFI/BOOT/BOOTX64.efi" ] && echo "✓" || echo "✗")"
log_info "grub (openEuler): $([ -f "$ESP_MOUNT/EFI/openEuler/grubx64.efi" ] && echo "✓" || echo "✗")"
log_info "grub (BOOT): $([ -f "$ESP_MOUNT/EFI/BOOT/grubx64.efi" ] && echo "✓" || echo "✗")"
log_info "kernel: $(ls "$ROOT_MOUNT/boot/vmlinuz-"* 2>/dev/null | head -1 | xargs basename || echo "✗")"
log_info "initramfs: $(ls "$ROOT_MOUNT/boot/initramfs-"* 2>/dev/null | head -1 | xargs basename || echo "✗")"

# ====== 卸载清理 ======
sudo umount "$ROOT_MOUNT/boot/efi" 2>/dev/null || true
sudo umount "$ROOT_MOUNT/dev" 2>/dev/null || true
sudo umount "$ROOT_MOUNT/proc" 2>/dev/null || true
sudo umount "$ROOT_MOUNT/sys" 2>/dev/null || true
sleep 2

sudo umount "$ESP_MOUNT" 2>/dev/null || {
    sudo fuser -km "$ESP_MOUNT" 2>/dev/null || true
    sleep 1
    sudo umount -f "$ESP_MOUNT" || true
}

sudo umount "$ROOT_MOUNT" 2>/dev/null || {
    sudo fuser -km "$ROOT_MOUNT" 2>/dev/null || true
    sleep 1
    sudo umount -f "$ROOT_MOUNT" || true
}

sleep 1
sudo losetup -d "$LOOP"
sudo rm -rf "$ESP_MOUNT" "$ROOT_MOUNT" 2>/dev/null || true

log_title "Success to create openEuler disk image!"
