#!/bin/bash
set -e

_current_path=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
_script_path=$(dirname $_current_path)
_secureboot_path=$(dirname $_script_path)
_artifact_path="$_secureboot_path/artifact"

OVMF_VAR_X86="$_artifact_path/ovmf/x86_sec_vars.fd"
OVMF_VAR_RV="$_artifact_path/ovmf/rv_sec_vars.fd"

SHIM_X86="$_artifact_path/shim/shimx64.efi"
SHIM_RV="$_artifact_path/shim/shimriscv64.efi"

keys_path="$_artifact_path/keys"
declare -A PK=(
   [key]="$keys_path/PK.key"
   [crt]="$keys_path/PK.crt"
   [cer]="$keys_path/PK.cer"
  #  [esl]="$keys_path/PK.esl"
  #  [auth]="$keys_path/PK.auth"
)
declare -A KEK=(
    [key]="$keys_path/KEK.key"
    [crt]="$keys_path/KEK.crt"
    [cer]="$keys_path/KEK.cer"
    # [esl]="$keys_path/KEK.esl"
    # [auth]="$keys_path/KEK.auth"
)

declare -A DB=(
    [key]="$keys_path/DB.key"
    [crt]="$keys_path/DB.crt"
    [cer]="$keys_path/DB.cer"
    # [esl]="$keys_path/DB.esl"
    # [auth]="$keys_path/DB.auth"
)

# rm -fr $keys_path
# mkdir -p $keys_path

# # ======  Generate New Keys  ====== #
# openssl req -new -x509 -newkey rsa:2048 -subj "/CN=Platform Key/" \
#   -keyout ${PK[key]} -out ${PK[crt]} -days 3650 -nodes -sha256

# openssl req -new -x509 -newkey rsa:2048 -subj "/CN=KEK/" \
#   -keyout ${KEK[key]} -out ${KEK[crt]} -days 3650 -nodes -sha256

# openssl req -new -x509 -newkey rsa:2048 -subj "/CN=DB/" \
#   -keyout ${DB[key]} -out ${DB[crt]} -days 3650 -nodes -sha256

# openssl x509 -in ${PK[crt]}  -outform DER -out ${PK[cer]}
# openssl x509 -in ${KEK[crt]} -outform DER -out ${KEK[cer]}
# openssl x509 -in ${DB[crt]}  -outform DER -out ${DB[cer]}
 
# uuidgen > $keys_path/PK.guid
# uuidgen > $keys_path/KEK.guid
# uuidgen > $keys_path/DB.guid

# echo "key generate success"
# ls -lh $keys_path/*.cer $keys_path/*.guid

# sudo apt install efitools
# cert-to-efi-sig-list -g "$(cat $keys_path/PK.guid)"  ${PK[crt]}  ${PK[esl]}
# cert-to-efi-sig-list -g "$(cat $keys_path/KEK.guid)" ${KEK[crt]} ${KEK[esl]}
# cert-to-efi-sig-list -g "$(cat $keys_path/DB.guid)"  ${DB[crt]}  ${DB[esl]}
# 
# sign-efi-sig-list -g "$(cat $keys_path/PK.guid)" -k ${PK[key]} -c ${PK[crt]} PK ${PK[esl]} $PK[auth]
# sign-efi-sig-list -g "$(cat $keys_path/KEK.guid)" -k ${KEK[key]} -c ${KEK[crt]} KEK ${KEK[esl]} ${KEK[auth]}
# sign-efi-sig-list -g "$(cat $keys_path/DB.guid)" -k ${DB[key}} -c ${DB[crt]} DB ${DB[esl]} ${DB[auth]}
# ls -lh $keys_path/*.auth


# ======  Inject Keys into Firmware  ====== #
# sudo apt install python3-virt-firmware

# x86 OVMF
# virt-fw-vars \
#   --input $OVMF_VAR_X86 \
#   --output $OVMF_VAR_X86 \
#   --set-pk "$(cat $keys_path/PK.guid)" ${PK[cer]} \
#   --add-kek "$(cat $keys_path/KEK.guid)" ${KEK[cer]} \
#   --add-db "$(cat $keys_path/DB.guid)" ${DB[cer]} \
#   --secure-boot

# RISC-V OVMF
virt-fw-vars \
  --input $OVMF_VAR_RV \
  --output $OVMF_VAR_RV \
  --set-pk "$(cat $keys_path/PK.guid)" ${PK[cer]} \
  --add-kek "$(cat $keys_path/KEK.guid)" ${KEK[cer]} \
  --add-db "$(cat $keys_path/DB.guid)" ${DB[cer]} \
  --secure-boot

# ======  Sign Shim  ====== #
# sbattach --remove $SHIM_X86 2>/dev/null || true

# sbsign --key ${DB[key]} --cert ${DB[crt]} --output $SHIM_X86 $SHIM_X86
# sbverify --cert ${DB[crt]} $SHIM_X86

# sbsign --key ${DB[key]} --cert ${DB[crt]} --output $SHIM_RV $SHIM_RV
# sbverify --cert ${DB[crt]} $SHIM_RV
