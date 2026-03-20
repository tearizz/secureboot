import struct

data = bytearray(open("/root/secureboot/artifact/shim/shimriscv64.efi", "rb").read())

# 第1步：从 0x3c 读出 PE 头的起始偏移
pe_off = struct.unpack_from('<I', data, 0x3c)[0]  # = 64

# 第2步：计算 Subsystem 字段的字节位置
#   PE签名4字节 + COFF头20字节 + 可选头偏移68 = 92
sub_off = pe_off + 4 + 20 + 68  # = 156

# 第3步：改写这2字节为 0x000A
data[sub_off : sub_off + 2] = struct.pack('<H', 0x0A)

open("shimriscv64.efi", "wb").write(data)
