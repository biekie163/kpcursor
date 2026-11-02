#!/usr/bin/env python3
# 检查一个 Mach-O（thin 或 fat）的切片构成，服务于 KPCursor 的硬性要求：
#   必须带 arm64e 切片 —— A12+ 的系统进程（SpringBoard / 设置）是 arm64e，
#   arm64-only 的镜像 dyld 根本不认，装上去的表现就是「没有任何反应」
#   （1.0-7 就是这样：设置不闪退，但插件根本没被加载，日志一个字都没有）。
#
# 另外把每个切片的 fixups 方式打出来，方便排查：
#   - dyld_chained_fixups=True  ：Apple ld64（macOS 构建）的正常产物，签名正确，可以用；
#   - 只有 dyld_info=True        ：老式 LC_DYLD_INFO；
#   - Linux 工具链也能产出 chained fixups，但 ptrauth 签名是坏的，
#     在 iOS 16.1.2 上会 SIGBUS / UNKNOWN_0x105（1.0-5、1.0-6 的崩溃），
#     所以本脚本不把「chained」当错误，真正的判据是「构建机是不是 macOS」
#     （见 .github/workflows/build.yml 的注释）。
import struct
import sys

LC_REQ_DYLD = 0x80000000
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x22 | LC_REQ_DYLD
LC_DYLD_CHAINED_FIXUPS = 0x34 | LC_REQ_DYLD

CPU_ARCH_ABI64 = 0x01000000
SUBTYPE_MASK = 0xFF000000
SUBTYPE_ARM64E = 2

ARM64 = 12 | CPU_ARCH_ABI64


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
    for cputype, cpusub, off, size in slices:
        name = arch_name(cputype, cpusub)
        cmds = load_commands(data, off)
        chained = LC_DYLD_CHAINED_FIXUPS in cmds
        classic = (LC_DYLD_INFO in cmds) or (LC_DYLD_INFO_ONLY in cmds)
        print("%s: size=%d  chained_fixups=%s  dyld_info=%s" % (name, size, chained, classic))
        if cputype == ARM64 and (cpusub & ~SUBTYPE_MASK) == SUBTYPE_ARM64E:
            has_arm64e = True
    if not has_arm64e:
        print("::error::没有 arm64e 切片（arm64-only 的镜像注入不了 SpringBoard/设置）")
        return 1
    print("OK: arm64e 切片存在")
    return 0


if __name__ == "__main__":
    sys.exit(main())
