#!/bin/bash

set -e

# 配置变量
_current_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
_script_path=$(dirname "$_current_path")
_secureboot_path=$(dirname "$_script_path")
_artifact_path="$_secureboot_path/artifact"

DISK_NAME="/$_artifact_path/image/pure_x86_ubuntu.img"
IMG_SIZE="10G"
MOUNT_POINT="/tmp/rootfs_mount"

echo "=== 清理旧文件 ==="
rm -f "$IMG_FILE"
mkdir -p "$MOUNT_POINT"

echo "=== 步骤 1: 创建磁盘镜像 ==="
qemu-img create -f raw "$IMG_FILE" "$IMG_SIZE"

echo "=== 步骤 2: 分区 ==="
sudo parted -s "$IMG_FILE" \
  mklabel msdos \
  mkpart primary ext4 1MiB 100%

echo "=== 步骤 3: 关联 loop 设备 ==="
LOOP=$(sudo losetup -f "$IMG_FILE" --show 2>&1 )
echo "Loop device: $LOOP"

# ===== 关键修复：强制扫描分区 =====
echo "=== 步骤 3.5: 扫描分区 ==="
sudo partprobe "$LOOP"
sleep 2

# 验证分区设备是否存在
echo "=== 验证分区设备 ==="
ls -la "${LOOP}"* || echo "分区设备不存在，尝试其他方法..."

# 如果还是不存在，手动触发
if [ ! -e "${LOOP}p1" ]; then
    echo "手动触发分区扫描..."
    sudo kpartx -av "$LOOP"
    sleep 2
    ls -la /dev/mapper/loop*
    PARTITION_DEV="/dev/mapper/$(basename $LOOP)p1"
else
    PARTITION_DEV="${LOOP}p1"
fi

echo "使用分区设备: $PARTITION_DEV"

echo "=== 步骤 4: 格式化文件系统 ==="
sudo mkfs.ext4 -F -L rootfs "$PARTITION_DEV"

echo "=== 步骤 5: 挂载分区 ==="
sudo mount "$PARTITION_DEV" "$MOUNT_POINT"

echo "=== 步骤 6: 使用 debootstrap 创建基础系统 ==="
sudo debootstrap --arch amd64 --include=openssh-server,vim,curl jammy "$MOUNT_POINT" http://archive.ubuntu.com/ubuntu

echo "=== 步骤 7: 创建 fstab ==="
sudo tee "$MOUNT_POINT/etc/fstab" > /dev/null <<'EOF'
/dev/hda1       /               ext4    defaults,errors=remount-ro 0 1
proc            /proc           proc    defaults        0 0
sysfs           /sys            sysfs   defaults        0 0
devtmpfs        /dev            devtmpfs defaults        0 0
tmpfs           /run            tmpfs   defaults        0 0
EOF

echo "=== 步骤 8: 配置网络 ==="
sudo tee "$MOUNT_POINT/etc/hostname" > /dev/null <<'EOF'
qemu-guest
EOF

sudo tee "$MOUNT_POINT/etc/hosts" > /dev/null <<'EOF'
127.0.0.1       localhost
127.0.1.1       qemu-guest
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

echo "=== 步骤 9: 设置 root 密码 ==="
sudo chroot "$MOUNT_POINT" /bin/bash <<'CHROOT'
echo "root:password" | chpasswd
exit
CHROOT

echo "=== 步骤 10: 验证文件系统结构 ==="
sudo ls -la "$MOUNT_POINT/" | head -20

echo "=== 步骤 11: 卸载 ==="
sudo umount "$MOUNT_POINT"

echo "=== 步骤 12: 清理设备映射 ==="
if [ -e "/dev/mapper/$(basename $LOOP)p1" ]; then
    sudo kpartx -dv "$LOOP"
fi

echo "=== 步骤 13: 卸载 loop 设备 ==="
sudo losetup -d "$LOOP"

echo "=== 完成！==="
ls -lh "$IMG_FILE"
