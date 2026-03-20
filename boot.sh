#!/bin/bash
set -e 

SCRIPT_NAME=$(basename "$0")

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
log_blank(){
  printf "${COLOR_RESET} %s\n" "$*" 
}

# ======  Artifact Configuration  ====== #
artifact_path="$PWD/artifact"
declare -A DISK_IMAGE=(
    [x86:ubuntu]="$artifact_path/image/x86_ubuntu.img"
    [x86:openEuler]="$artifact_path/image/x86_openEuler.img"
    [rv:ubuntu]=""
    [rv:openEuler]="$artifact_path/image/rv_openEuler.img"
)

declare -A OVMF_CODE=(
    [x86:secureboot]="$artifact_path/ovmf/x86_sec_code.fd"
    [x86:unsecureboot]=""
    [rv:secureboot]="$artifact_path/ovmf/rv_sec_code.fd"
    [rv:unsecureboot]="$artifact_path/ovmf/rv_unsec_code.fd"
)

declare -A OVMF_VARS=(
    [x86:secureboot]="$artifact_path/ovmf/x86_sec_vars.fd"
    [x86:unsecureboot]=""
    [rv:secureboot]="$artifact_path/ovmf/rv_sec_vars.fd"
    [rv:unsecureboot]="$artifact_path/ovmf/rv_unsec_vars.fd"
)

# ======  Command Args  ====== #
usage() {
    cat <<EOF
用法： $SCRIPT_NAME [选项] <参数>...
选项：
    -h, --help      获取帮助
    -a, --arch <>   启动的虚机架构(64位)
    -k, --kernel <> 启动的系统内核
    --secureboot    启用安全启动
    --unsecureboot  关闭安全启动
EOF
    log_blank
    exit 0
}

# Parse Args by Getopt
SHORT_OPTS="ha:k:"
LONG_OPTS="help,arch:,kernel:,secureboot,unsecureboot"

ARGS=$(getopt -o "$SHORT_OPTS" -l "$LONG_OPTS" -n "$SCRIPT_NAME" -- "$@")
if [ $? -ne 0 ]; then
    exit
fi

eval set -- "$ARGS"

ARCH=""
KERNEL=""
SECURE_BOOT=""

while true; do
    case "$1" in 
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -k|--kernel)
            KERNEL="$2"
            shift 2
            ;;
        --secureboot)
            SECURE_BOOT="secureboot"
            shift
            ;;
        --unsecureboot)
            SECURE_BOOT="unsecureboot"
            shift
            ;;
        --)
            shift   # "--" 代表选项结束，退出循环
            break
            ;;
        *)
            echo "内部错误"
            exit 1
            ;;
    esac
done

# Store Position Args
TARGET="$@"

# Check Args Validity
error_flag=0
if [ -z "$ARCH" ]; then
    log_error "必须指定架构：-a|--arch=<rv,x86>"
    error_flag=1
elif [[ "$ARCH" != "rv" && "$ARCH" != "x86" ]]; then
    log_error "ARCH 必须为 'rv' 或 'x86'"
    error_flag=1
fi

if [ -z "$KERNEL" ]; then
    log_error "必须指定内核：-k|--kernel=<openEuler,ubuntu>"
    error_flag=1
elif [[ "$KERNEL" != "openEuler" && "$KERNEL" != "ubuntu" ]]; then
    log_error "KERNEL 必须为 'openEuler' 或 'ubuntu'"
    error_flag=1
fi

if [[ $SECURE_BOOT != "secureboot" && $SECURE_BOOT != "unsecureboot" ]]; then
    log_error "必须指定是否开启安全启动：--secureboot | --unsecureboot"
    error_flag=1
fi

if [[ error_flag -ne 0 ]]; then
    log_blank
    usage
fi


# ======  Compose Qemu Command  ====== #
BaseCommand=(sudo -S)

if [[ $ARCH = "x86" ]]; then
    BaseCommand+=(qemu-system-x86_64)
    BaseCommand+=(-machine q35,smm=on)
    BaseCommand+=(-cpu host --enable-kvm)
    BaseCommand+=(-vga std)
    BaseCommand+=(-device isa-debug-exit,iobase=0xf4,iosize=0x04)
    BaseCommand+=(-device virtio-net-pci,netdev=net0,mac=52:54:00:00:00:01)
    BaseCommand+=(-device virtio-rng-pci)
    BaseCommand+=(-nodefaults)
else
    BaseCommand+=(qemu-system-riscv64)
    BaseCommand+=(-machine virt,pflash0=pflash0,pflash1=pflash1)
    # virtio-blk-pci uses PCIe enumeration (done during DXE) rather than MMIO
    # FDT discovery, so the FAT32 filesystem is available earlier at BDS time.
    BaseCommand+=(-device virtio-blk-pci,drive=disk0)
    BaseCommand+=(-device virtio-net-pci,netdev=net0,mac=52:54:00:00:00:01)
    BaseCommand+=(-device virtio-rng-pci)
fi

BaseCommand+=(-boot menu=on,splash-time=0)
BaseCommand+=(-smp 4 -m 4G)
BaseCommand+=(-no-reboot -nographic)
BaseCommand+=(-serial mon:stdio)
BaseCommand+=(-netdev user,id=net0,net=192.168.17.0/24)

CODE=${OVMF_CODE[$ARCH:$SECURE_BOOT]}
VARS=${OVMF_VARS[$ARCH:$SECURE_BOOT]}
VARS_RUNTIME=$(mktemp /tmp/ovmf_vars_XXXXXX.fd)

cp "$VARS" "$VARS_RUNTIME"
VARS_SAVED="/tmp/rv_ovmf_vars_last.fd"
# Keep a copy after QEMU exits so we can inspect what BootOrder OVMF wrote back.
trap '[[ "$ARCH" = "rv" ]] && cp "$VARS_RUNTIME" "$VARS_SAVED" 2>/dev/null; rm -f "$VARS_RUNTIME"' EXIT

# OVMF's RiscVVirt platform code dynamically creates Boot0000 "UEFI Misc Device"
# pointing at VenHw(837DCA9E...) on every boot.  In QEMU 10.x that device no
# longer supports direct booting, so BDS fails before reaching the ESP fallback.
# Fix: inject an explicit FilePath boot entry pointing at \EFI\BOOT\BOOTRISCV64.EFI
# *before* QEMU starts.  OVMF finds Boot0000 already set, uses it, and BDS scans
# all file systems to expand the short-form path and load the shim.
if [[ "$ARCH" = "rv" ]] && command -v virt-fw-vars >/dev/null 2>&1; then
  del_args=()
  for i in {0..31}; do
    del_args+=(--delete "$(printf 'Boot%04X' $i)")
  done
  virt-fw-vars --inplace "$VARS_RUNTIME" \
    "${del_args[@]}" --delete BootOrder --delete BootNext \
    >/dev/null 2>&1 || true

  # Create Boot0000 = FilePath(BOOTRISCV64.EFI) + BootOrder=[0000]
  virt-fw-vars --inplace "$VARS_RUNTIME" \
    --append-boot-filepath '\\EFI\\BOOT\\BOOTRISCV64.EFI' \
    >/dev/null 2>&1

  # Set BootNext=0x0000 so BDS tries Boot0000 BEFORE BootOrder, even if
  # OVMF's PlatformBootManagerLib overwrites BootOrder at runtime.
  # BootNext is a one-shot variable: cleared by firmware after one use.
  _bootjson=$(mktemp /tmp/bootnext_XXXXXX.json)
  cat > "$_bootjson" <<'JSON'
{
    "version": 2,
    "variables": [
        {
            "name": "BootNext",
            "guid": "8be4df61-93ca-11d2-aa0d-00e098032b8c",
            "attr": 7,
            "data": "0000"
        }
    ]
}
JSON
  virt-fw-vars --inplace "$VARS_RUNTIME" --set-json "$_bootjson" >/dev/null 2>&1 || true
  rm -f "$_bootjson"
fi

BaseCommand+=(-blockdev node-name=pflash0,driver=file,read-only=on,filename=$CODE)
BaseCommand+=(-blockdev node-name=pflash1,driver=file,filename=$VARS_RUNTIME)

DISK=${DISK_IMAGE[$ARCH:$KERNEL]}
if [[ $ARCH = "x86" ]]; then
    BaseCommand+=(-drive if=ide,format=raw,file=$DISK)
else
    BaseCommand+=(-drive id=disk0,format=raw,file=$DISK,if=none)
fi

# ======  Run Qemu  ====== #
"${BaseCommand[@]}"
# echo ${BaseCommand[@]}
