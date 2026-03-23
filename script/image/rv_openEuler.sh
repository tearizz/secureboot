#!/bin/bash
set -e

# ======  Log Configuration  ====== #
COLOR_INFO='\033[0;32m'
COLOR_WARN='\033[1;33m'
COLOR_ERROR='\033[0;31m'
COLOR_TITLE='\033[0;35m'
COLOR_RESET='\033[0m'

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

_current_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
_script_path=$(dirname "$_current_path")
_secureboot_path=$(dirname "$_script_path")
_artifact_path="$_secureboot_path/artifact"

DISK_NAME="$_artifact_path/image/rv_openEuler.img"
DISK_NAME_TMP="${DISK_NAME}.tmp.$$"
SHIM="$_artifact_path/shim/shimriscv64.efi"
MMX="$_artifact_path/shim/mmriscv64.efi"
BOOTRISCV64_CSV="$_artifact_path/shim/BOOTRISCV64.CSV"

DB_PRIV_KEY="$_artifact_path/keys/DB.key"
DB_CERT="$_artifact_path/keys/DB.crt"
VENDOR_PRIV_KEY=$DB_PRIV_KEY
VENDOR_CERT=$DB_CERT

for file in "$SHIM" "$MMX" "$BOOTRISCV64_CSV" "$DB_PRIV_KEY" "$DB_CERT"; do
  [ -f "$file" ] || log_error "$file does not exist"
done

LOOP=""
ESP_MOUNT=""
ROOT_MOUNT=""
cleanup() {
  sudo umount "$ROOT_MOUNT/boot/efi" 2>/dev/null || true
  sudo umount "$ROOT_MOUNT/dev" 2>/dev/null || true
  sudo umount "$ROOT_MOUNT/proc" 2>/dev/null || true
  sudo umount "$ROOT_MOUNT/sys" 2>/dev/null || true
  sudo umount "$ESP_MOUNT" 2>/dev/null || true
  sudo umount "$ROOT_MOUNT" 2>/dev/null || true
  [ -n "$LOOP" ] && sudo losetup -d "$LOOP" 2>/dev/null || true
  sudo rm -rf "$ESP_MOUNT" "$ROOT_MOUNT" 2>/dev/null || true
  rm -f "$DISK_NAME_TMP" 2>/dev/null || true
}
trap cleanup EXIT

log_title "Create and part single RISC-V disk"
rm -f "$DISK_NAME_TMP"
qemu-img create -f raw "$DISK_NAME_TMP" 12G
sudo parted -s "$DISK_NAME_TMP" \
  mklabel gpt \
  mkpart ESP fat32 1MiB 512MiB \
  set 1 esp on \
  mkpart primary ext4 512MiB 100%

LOOP=$(sudo losetup -f -P "$DISK_NAME_TMP" --show)
sleep 2
sudo mkfs.fat -F32 -n ESP "${LOOP}p1"
sudo mkfs.ext4 -F -L rootfs "${LOOP}p2"

ESP_MOUNT="/tmp/esp_fixed_$$"
ROOT_MOUNT="/tmp/root_fixed_$$"
mkdir -p "$ESP_MOUNT" "$ROOT_MOUNT"
sudo mount "${LOOP}p1" "$ESP_MOUNT"
sudo mount "${LOOP}p2" "$ROOT_MOUNT"

ROOT_UUID=$(sudo blkid -s UUID -o value "${LOOP}p2")
ESP_UUID=$(sudo blkid -s UUID -o value "${LOOP}p1")
log_info "rootfs UUID: $ROOT_UUID"
log_info "esp UUID: $ESP_UUID"

sudo mkdir -p "$ESP_MOUNT/EFI/BOOT" "$ESP_MOUNT/EFI/openEuler"
sudo cp "$SHIM" "$ESP_MOUNT/EFI/BOOT/BOOTRISCV64.EFI"
sudo cp "$SHIM" "$ESP_MOUNT/EFI/openEuler/shimriscv64.efi"
sudo cp "$MMX" "$ESP_MOUNT/EFI/openEuler/mmriscv64.efi"
sudo cp "$BOOTRISCV64_CSV" "$ESP_MOUNT/EFI/openEuler/BOOTRISCV64.CSV"


log_title "Install OpenEuler RISC-V rootfs via Docker"
# docker pull hub.oepkgs.net/openeuler/openeuler:24.03-lts
sudo docker run --privileged --rm \
  -e "ROOT_UUID=$ROOT_UUID" \
  -e "ESP_UUID=$ESP_UUID" \
  -v "$ROOT_MOUNT":/mnt/rootfs \
  hub.oepkgs.net/openeuler/openeuler:24.03-lts \
  /bin/bash -c "$(cat <<'INNER'
set -e

dnf install -y util-linux > /dev/null

mkdir -p /mnt/rootfs/{dev,proc,sys,run,var/log}
if ! grep -q " /mnt/rootfs/dev " /proc/mounts 2>/dev/null; then
  mount --bind /dev /mnt/rootfs/dev
fi
if [ ! -e /mnt/rootfs/proc/meminfo ]; then
  mount -t proc proc /mnt/rootfs/proc
fi
if [ ! -d /mnt/rootfs/sys/kernel ]; then
  mount -t sysfs sys /mnt/rootfs/sys
fi
if ! grep -q " /mnt/rootfs/run " /proc/mounts 2>/dev/null; then
  mount -t tmpfs tmpfs /mnt/rootfs/run
fi

dnf install -y --installroot=/mnt/rootfs \
  --releasever=24.03 \
  --forcearch=riscv64 \
  --repofrompath=openeuler,https://repo.openeuler.org/openEuler-24.03-LTS/OS/riscv64/ \
  bash coreutils systemd dnf kernel mokutil \
  grub2-efi-riscv64 efibootmgr grub2-efi-riscv64-modules \
  --nogpgcheck

cp /etc/resolv.conf /mnt/rootfs/etc/
cat > /mnt/rootfs/etc/fstab <<EOF
UUID=${ROOT_UUID} /               ext4    defaults,errors=remount-ro 0       1
UUID=${ESP_UUID}  /boot/efi       vfat    umask=0077,nofail 0                0
proc              /proc           proc    defaults                   0       0
sysfs             /sys            sysfs   defaults                   0       0
devtmpfs          /dev            devtmpfs defaults                  0       0
tmpfs             /run            tmpfs   defaults                   0       0
EOF

echo "openeuler-riscv" > /mnt/rootfs/etc/hostname
cat > /mnt/rootfs/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   openeuler-riscv
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

sed -i 's|^root:[^:]*:|root::|' /mnt/rootfs/etc/shadow
mkdir -p /mnt/rootfs/boot/grub2 /mnt/rootfs/boot/efi
INNER
)"

log_title "Build grub EFI on host"
if ! command -v grub-mkimage > /dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y grub2-common
fi

GRUB_MODULE_DIR=$(ls -d "$ROOT_MOUNT"/usr/lib*/grub/riscv64-efi 2>/dev/null | head -1)
[ -n "$GRUB_MODULE_DIR" ] || log_error "riscv64-efi grub modules not found"

cat > /tmp/grub_sbat.csv << 'SBAT_EOF'
sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md
grub,4,Free Software Foundation,grub,2.12,https://www.gnu.org/software/grub/
grub.openeuler,1,openEuler,grub2,2.12,https://repo.openeuler.org
SBAT_EOF

sudo grub-mkimage \
  -d "$GRUB_MODULE_DIR" \
  -o "$ESP_MOUNT/EFI/openEuler/grubriscv64.efi" \
  --sbat /tmp/grub_sbat.csv \
  -O riscv64-efi \
  -p /EFI/openEuler \
  part_gpt part_msdos fat ext2 normal \
  configfile linux search search_fs_uuid \
  search_label echo test cat ls loadenv \
  minicmd boot chain reboot halt gzio fdt

log_title "Generate QEMU virt DTB"
# -bios none: skip firmware so dumpdtb runs before any init failure.
TEMP_DTB="/tmp/riscv-virt-dtb-$$.dtb"
command -v qemu-system-riscv64 >/dev/null 2>&1 || log_error "qemu-system-riscv64 not in PATH"
timeout 30 qemu-system-riscv64 \
  -bios none \
  -machine "virt,dumpdtb=${TEMP_DTB}" \
  -display none -m 256M -nographic || true
[[ -f "$TEMP_DTB" && -s "$TEMP_DTB" ]] || log_error "Failed to generate DTB"
sudo cp "$TEMP_DTB" "$ROOT_MOUNT/boot/riscv-virt.dtb"

rm -f "$TEMP_DTB"
log_info "DTB saved to rootfs $ROOT_MOUNT/boot/riscv-virt.dtb"

KERNEL_VER=$(ls "$ROOT_MOUNT"/boot/vmlinuz-* 2>/dev/null | head -1 | sed 's|.*/vmlinuz-||')
[ -n "$KERNEL_VER" ] || log_error "no kernel found in rootfs"

sudo tee "$ESP_MOUNT/EFI/openEuler/grub.cfg" > /dev/null << GRUBCFGEOF
set default=0
set timeout=10
search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
menuentry "openEuler RISC-V" {
    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}
    devicetree /boot/riscv-virt.dtb
    linux  /boot/vmlinuz-${KERNEL_VER} root=UUID=${ROOT_UUID} rw earlycon=sbi console=ttyS0,115200n8
    initrd /boot/initramfs-${KERNEL_VER}.img
}
GRUBCFGEOF
sudo cp "$ESP_MOUNT/EFI/openEuler/grub.cfg" "$ROOT_MOUNT/boot/grub2/grub.cfg"

log_title "Sign shim and grub"
if ! command -v sbsign > /dev/null; then
  sudo apt-get update
  sudo apt-get install -y sbsigntool
fi

sbverify --cert "$DB_CERT" "$ESP_MOUNT/EFI/BOOT/BOOTRISCV64.EFI"

GRUB_EFI="$ESP_MOUNT/EFI/openEuler/grubriscv64.efi"
[ -f "$GRUB_EFI" ] || log_error "grubriscv64.efi not found"
sbsign --key "$VENDOR_PRIV_KEY" --cert "$VENDOR_CERT" --output "$GRUB_EFI" "$GRUB_EFI"
sbverify --cert "$VENDOR_CERT" "$GRUB_EFI"

sudo cp "$GRUB_EFI" "$ESP_MOUNT/EFI/BOOT/grubriscv64.efi"

log_title "Check ESP files"
find "$ESP_MOUNT" -type f | sort
mv -f "$DISK_NAME_TMP" "$DISK_NAME"
log_title "Success! Created rv_openEuler.img"