#!/usr/bin/env python3
# 检查一个 Mach-O（thin 或 fat）的切片构成，专门服务于 KPCursor 的两个硬性要求：
#   1) 必须带 arm64e 切片 —— A12+ 的系统进程是 arm64e，arm64-only 的镜像 dyld 不认；
#   2) arm64e 切片不能带 LC_DYLD_CHAINED_FIXUPS —— Linux 工具链产出的 chained fixups
#      在 iOS 16.1.2 上验签失败，dyld 一映射 ObjC 元数据就 SIGBUS/UNKNOWN_0x105。
# 当年 1.0-5/1.0-6 的黑屏、1.0-7 的「装了没反应」，就是这两条之一没满足。
import struct
import sys

LC_REQ_DYLD = 0x80000000
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x22 | LC_REQ_DYLD
LC_DYLD_CHAINED_FIXUPS = 0x34 | LC_REQ_DYLD

CPU_ARCH_ABI64 = 0x01000000
CPU_TYPE_ARM64 = 12 | CPU_ARCH_ABI64
SUBTYPE_MASK = 0xFF000000
SUBTYPE_ARM64E = 2

ARM64 = 0x0100000C


def arch_name(cputype, cpusub):
    if cputype == ARM64:
        sub = cpusub & ~SUBTYPE_MASK
        if sub == SUBTYPE_ARM64E:
            return "arm64e"
        if sub == 0:
            return "arm64"
        return "arm64(sub=0x%x)" % sub
    return "cputype=0x%x sub=0x%x" % (cputype, cpusub)


def read_slices(data):
    magic = struct.unpack(">I", data[:4])[0]
    if magic == 0xCAFEBABE:
        count = struct.unpack(">I", data[4:8])[0]
        out = []
        for i in range(count):
            base = 8 + 20 * i
            cputype, cpusub, off, size, _align = struct.unpack(">iiIII", data[base:base + 20])
            out.append((cputype, cpusub, off, size))
        return out
    # thin
    cputype, cpusub = struct.unpack("<ii", data[4:12])
    return [(cputype, cpusub, 0, len(data))]


def load_commands(data, off):
    magic = struct.unpack("<I", data[off:off + 4])[0]
    if magic == 0xFEEDFACF:
        header_size = 32
    elif magic == 0xFEEDFACE:
        header_size = 28
    else:
        raise SystemExit("not a Mach-O at offset 0x%x (magic 0x%x)" % (off, magic))
    ncmds = struct.unpack("<I", data[off + 16:off + 20])[0]
    p = off + header_size
    cmds = []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[p:p + 8])
        cmds.append(cmd)
        if cmdsize < 8:
            break
        p += cmdsize
    return cmds


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: check_macho.py <macho>")
    path = sys.argv[1]
    data = open(path, "rb").read()
    slices = read_slices(data)
    has_arm64e = False
    problems = []
    for cputype, cpusub, off, size in slices:
        name = arch_name(cputype, cpusub)
        cmds = load_commands(data, off)
        chained = LC_DYLD_CHAINED_FIXUPS in cmds
        classic = (LC_DYLD_INFO in cmds) or (LC_DYLD_INFO_ONLY in cmds)
        print("%s: %s  size=%d  chained_fixups=%s  dyld_info=%s"
              % (name, "arm64e" if (cputype == ARM64 and (cpusub & ~SUBTYPE_MASK) == SUBTYPE_ARM64E) else "-",
                 size, chained, classic))
        if cputype == ARM64 and (cpusub & ~SUBTYPE_MASK) == SUBTYPE_ARM64E:
            has_arm64e = True
            if chained:
                problems.append("arm64e 切片带了 LC_DYLD_CHAINED_FIXUPS（iOS 16.1.2 上会 SIGBUS）")
    if not has_arm64e:
        problems.append("没有 arm64e 切片（arm64-only 的镜像注入不了 SpringBoard/设置）")
    if problems:
        for p in problems:
            print("::error::" + p)
        return 1
    print("OK: arm64e 切片存在，且走的是老式 LC_DYLD_INFO")
    return 0


if __name__ == "__main__":
    sys.exit(main())
