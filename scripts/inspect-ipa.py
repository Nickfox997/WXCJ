#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
解析注入后的 IPA，验证插件是否真的被注入。

用法：
    python scripts/inspect-ipa.py <path-to-injected.ipa>

检查项：
  1. Frameworks/libmarsbridge.dylib 是否存在
  2. 主程序是否真的插入了 LC_LOAD_DYLIB 指向它（这一步没做 = 插件不会被加载）
  3. 主程序是否已砸壳（cryptid）
  4. 架构列表（arm64 / arm64e）
  5. dylib 自身的 install_name 与实际落地路径是否一致
"""

import sys
import os
import struct
import zipfile

LC_ENCRYPTION_INFO      = 0x21
LC_ENCRYPTION_INFO_64   = 0x2C
LC_LOAD_DYLIB           = 0x0C
LC_LOAD_WEAK_DYLIB      = 0x80000018
LC_REEXPORT_DYLIB       = 0x8000001F
LC_ID_DYLIB             = 0x0D

CPU = {0x0100000C: "arm64", 0x0100000D: "arm64e", 0x0000000C: "arm", 0x01000007: "x86_64"}
DYLIB_CMDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB)


def cstr(data, start, end):
    return data[start:end].split(b"\0")[0].decode("utf-8", "replace")


def parse_thin(data, base=0):
    """解析单个 Mach-O slice，返回 (cputype, dylibs[], cryptid, id_name)"""
    magic = struct.unpack_from("<I", data, base)[0]
    if magic not in (0xFEEDFACF, 0xFEEDFACE):
        return None
    cputype = struct.unpack_from("<i", data, base + 4)[0]
    ncmds   = struct.unpack_from("<I", data, base + 16)[0]
    off = base + (32 if magic == 0xFEEDFACF else 28)

    dylibs, cryptid, idname = [], None, None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd in DYLIB_CMDS or cmd == LC_ID_DYLIB:
            nameoff = struct.unpack_from("<I", data, off + 8)[0]
            name = cstr(data, off + nameoff, off + cmdsize)
            if cmd == LC_ID_DYLIB:
                idname = name
            else:
                dylibs.append(name)
        elif cmd in (LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64):
            cryptid = struct.unpack_from("<I", data, off + 16)[0]
        off += cmdsize
    return (CPU.get(cputype, hex(cputype)), dylibs, cryptid, idname)


def parse_macho(data):
    """自动处理 fat / thin"""
    if len(data) < 8:
        return []
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic == 0xCAFEBABE:  # fat
        nfat = struct.unpack_from(">I", data, 4)[0]
        out = []
        for i in range(nfat):
            base_off = 8 + i * 20
            cputype, _, offset, size, _ = struct.unpack_from(">iiIII", data, base_off)
            r = parse_thin(data, offset)
            if r:
                out.append(r)
        return out
    r = parse_thin(data, 0)
    return [r] if r else []


def main():
    if len(sys.argv) < 2:
        print("用法: python inspect-ipa.py <ipa路径>")
        return 1
    ipa = sys.argv[1]
    if not os.path.exists(ipa):
        print(f"[!] 文件不存在: {ipa}")
        return 1

    print(f"检查: {ipa}")
    print(f"大小: {os.path.getsize(ipa)/1024/1024:.1f} MB\n")

    ok = True
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        apps = [n for n in names if n.startswith("Payload/") and n.count("/") == 2
                and n.endswith(".app/")]
        if not apps:
            print("[!] 没找到 Payload/*.app/ —— 这不是标准 IPA")
            return 1
        app = apps[0]
        print(f"App 目录: {app}")

        # 1) dylib 是否存在
        dylibs_in_ipa = [n for n in names if n.endswith(".dylib")]
        print(f"\n[1] IPA 里的 dylib ({len(dylibs_in_ipa)} 个):")
        target = None
        for n in dylibs_in_ipa:
            mark = ""
            if "marsbridge" in n.lower():
                target = n
                mark = "  <-- 我们的插件"
            print(f"    {n}{mark}")
        if not target:
            print("    [!] 没有找到 marsbridge dylib —— 注入没成功")
            ok = False

        # 2) 主程序是否引用它
        exe = None
        for n in names:
            if n.startswith(app) and n.count("/") == app.count("/") + 1 and "/" not in n[len(app):]:
                cand = z.getinfo(n)
                if cand.file_size > 1024 * 1024:
                    exe = n
                    break
        if not exe:
            print("\n[!] 找不到主可执行文件")
            return 1
        print(f"\n[2] 主可执行文件: {exe}")
        data = z.read(exe)
        slices = parse_macho(data)

        found_load = False
        for cpu, dylibs, cryptid, _ in slices:
            enc = {0: "已砸壳 (cryptid 0)", 1: "仍加密 (cryptid 1)",
                   None: "无加密段"}.get(cryptid, f"cryptid {cryptid}")
            print(f"    架构 {cpu}: {enc}")
            if cryptid == 1:
                ok = False
                print("        [!] 未砸壳，注入必然闪退")
            for d in dylibs:
                if "marsbridge" in d.lower():
                    found_load = True
                    print(f"        [OK] LC_LOAD_DYLIB -> {d}")

        print(f"\n[3] 注入结论: ", end="")
        if found_load:
            print("主程序已引用插件 dylib")
        else:
            print("主程序【没有】引用插件 dylib —— 这是插件不加载的直接原因")
            ok = False

        # 4) dylib 自身检查
        if target:
            print(f"\n[4] 插件 dylib 自检 ({target}):")
            dd = z.read(target)
            ds = parse_macho(dd)
            for cpu, dylibs, cryptid, idname in ds:
                print(f"    架构: {cpu}")
                print(f"    install_name: {idname}")
                expect = "@executable_path/Frameworks/libmarsbridge.dylib"
                if idname and "marsbridge" in (idname or ""):
                    if idname == expect:
                        print("        [OK] install_name 与落地路径一致")
                    else:
                        print(f"        [!] install_name 是 {idname}")
                        print(f"            却放在 {target}")
                        print(f"            期望 {expect}")

        print()
        print("=" * 56)
        print("结论: " + ("注入看起来完整，问题在插件运行时（看自检诊断）"
                        if ok else "注入链路有问题，见上面的 [!] 项"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
