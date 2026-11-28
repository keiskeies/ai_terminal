#!/usr/bin/env python3
"""Pack Termux's busybox + bash into android/app/src/main/jniLibs.

Android 10+ (targetSdk >= 29) refuses execve() on ELF living in the app's own
data directory, so a Termux-style userspace can only run from nativeLibraryDir,
which is the one app-writable-at-install location whose files are labelled
apk_data_file and therefore executable. Two properties of the upstream binaries
stop them working there as-is, and this script repairs both:

  * DT_RUNPATH is hardcoded to /data/data/com.termux/files/usr/lib
  * DT_NEEDED / DT_SONAME use versioned names ("libbusybox.so.1.38.0") while
    jniLibs only packages "lib*.so" and the linker resolves by that name.

Both are repaired by *shortening* the string in .dynstr and NUL-padding what is
left over. Shortening never moves a byte, so every st_name offset in .dynsym
stays valid -- lengthening would not have that property. Suffix merging means a
tail we NUL over could host another string's start, so referenced offsets are
checked before anything is written.
"""

from __future__ import annotations

import argparse
import os
import re
import struct
import subprocess
import sys
import tarfile
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

REPOS = {
    "aarch64": "https://packages.termux.dev/apt/termux-main",
    "arm": "https://packages.termux.dev/apt/termux-main",
    "x86_64": "https://packages.termux.dev/apt/termux-main",
}
ABI_OF = {"aarch64": "arm64-v8a", "arm": "armeabi-v7a", "x86_64": "x86_64"}

# package -> (path inside data.tar.xz, shipped-as name in jniLibs)
TARGETS = {
    "busybox": [
        ("bin/busybox", "libbbmain.so"),
        ("lib/libbusybox.so.1.38.0", "libbb.so"),
    ],
    "libandroid-selinux": [("lib/libandroid-selinux.so", None)],
    "pcre2": [("lib/libpcre2-8.so", None)],
    "bash": [("bin/bash", "libbash.so")],
    "libandroid-support": [("lib/libandroid-support.so", None)],
    "readline": [("lib/libreadline.so.8.3", "libreadline8.so")],
    "ncurses": [("lib/libncursesw.so.6.5", "libncursesw6.so")],
    "libiconv": [("lib/libiconv.so", None)],
}

# Only ever replace with something shorter; see module docstring.
REWRITE = {
    "/data/data/com.termux/files/usr/lib": "$ORIGIN",
    "libbusybox.so.1.38.0": "libbb.so",
    "libreadline.so.8": "libreadline8.so",
    "libncursesw.so.6": "libncursesw6.so",
}

DT = {1: "NEEDED", 14: "SONAME", 15: "RPATH", 29: "RUNPATH"}

# .rodata 里编译期写死的 Termux 路径。这些不是链接器指令，改错了不会报错、
# 只会行为诡异，所以逐条要求「精确匹配 + 更短」，否则直接失败。
# bash 每次读完 rc 都会去 source 这个系统级 rc 并在失败时打印
# "<bash路径>: <该路径>: Permission denied"——在交互终端里每一行提示符都会
# 重复一遍，只能从字符串本身掐掉。指向一个确定不存在的文件即可静音。
RODATA_REWRITE = {
    "libbash.so": [
        ("/data/data/com.termux/files/usr/etc/bash.bashrc",
         "/system/etc/nonexistent-bash.bashrc"),
        ("/data/data/com.termux/files/usr/etc/profile",
         "/system/etc/nonexistent-profile"),
    ],
}
PT_DYNAMIC, PT_LOAD = 2, 1
SZ64 = "<IIQQQQIIQQ"


def log(msg: str) -> None:
    print(msg, flush=True)


# ---------------------------------------------------------------- apt side --

def fetch_index(arch: str, cache: str) -> str:
    url = f"{REPOS[arch]}/dists/stable/main/binary-{arch}/Packages"
    path = os.path.join(cache, f"Packages.{arch}")
    if not os.path.exists(path) or os.path.getsize(path) < 100_000:
        log(f"fetch index {arch}")
        urllib.request.urlretrieve(url, path + ".part")
        os.replace(path + ".part", path)
    return path


def parse_index(path: str) -> dict[str, dict[str, str]]:
    out: dict[str, dict[str, str]] = {}
    for blk in open(path, encoding="utf-8", errors="replace").read().split("\n\n"):
        d = {}
        for line in blk.split("\n"):
            m = re.match(r"^([A-Za-z-]+):\s*(.*)$", line)
            if m:
                d[m.group(1)] = m.group(2)
        if "Package" in d:
            out[d["Package"]] = d
    return out


def ar_member(deb: str, want_prefix: str) -> bytes:
    blob = open(deb, "rb").read()
    if blob[:8] != b"!<arch>\n":
        raise SystemExit(f"{deb}: not an ar archive")
    off = 8
    while off + 60 <= len(blob):
        hdr = blob[off : off + 60]
        name = hdr[0:16].decode("ascii", "replace").strip().rstrip("/")
        size = int(hdr[48:58].decode("ascii").strip())
        if name.startswith(want_prefix):
            return blob[off + 60 : off + 60 + size]
        off += 60 + size + (size & 1)
    raise SystemExit(f"{deb}: no {want_prefix} member")


def get_files(pkg: str, arch: str, cache: str) -> dict[str, bytes]:
    idx = parse_index(fetch_index(arch, cache))
    meta = idx.get(pkg)
    if not meta:
        raise SystemExit(f"package {pkg} not in index for {arch}")
    deb = os.path.join(cache, f"{pkg}.{arch}.deb")
    want = int(meta.get("Size", "-1"))
    if not os.path.exists(deb) or os.path.getsize(deb) != want:
        url = REPOS[arch] + "/" + meta["Filename"]
        log(f"fetch {pkg} ({want/1024:.0f}K)")
        urllib.request.urlretrieve(url, deb + ".part")
        os.replace(deb + ".part", deb)
    data = ar_member(deb, "data.tar")
    out: dict[str, bytes] = {}
    import io

    with tarfile.open(fileobj=io.BytesIO(data)) as tf:
        for m in tf.getmembers():
            if not m.isfile() and not m.issym():
                continue
            # data.tar nests the whole prefix: ./data/data/com.termux/files/usr/...
            key = m.name.split("files/usr/", 1)
            if len(key) != 2 or not m.isfile():
                continue
            out[key[1]] = tf.extractfile(m).read()
    return out


def license_id(pkg: str, arch: str, cache: str) -> str:
    """Read the licence id out of the deb that is actually being shipped.

    Reading it from the package rather than keeping a hand-typed table is the
    point: the notice then cannot drift away from the binaries. There is no
    single convention to rely on -- Termux uses a copyright symlink named after
    the licence id, pcre2 ships the id inside a markdown table, and a
    dual-licensed package appends the alternative as copyright.1 -- so every
    doc file is consulted and the identified ids win over unidentified ones.
    """
    import io

    doc_of = re.compile(r"share/doc/[^/]+/(.*)$")
    name_of = re.compile(
        r"(?i)^(copyright|copying|licen[cs]e)(\.md|\.txt)?(\.\d+)?$"
    )
    deb = os.path.join(cache, f"{pkg}.{arch}.deb")
    tf = tarfile.open(fileobj=io.BytesIO(ar_member(deb, "data.tar")))
    found: set[str] = set()
    unidentified = 0
    for m in tf.getmembers():
        # Same nesting as get_files(): ./data/data/com.termux/files/usr/share/...
        parts = m.name.split("files/usr/", 1)
        if len(parts) != 2:
            continue
        leaf_m = doc_of.match(parts[1])
        if not leaf_m or not name_of.match(leaf_m.group(1)):
            continue
        if m.issym():
            found.add(os.path.basename(m.linkname).removesuffix(".txt"))
            continue
        if not m.isfile():  # e.g. share/doc/pcre2/html/
            continue
        head = tf.extractfile(m).read(4096).decode("utf-8", "replace")
        # pcre2 puts the id in a markdown table row: "| SPDX-...: | X |".
        m2 = re.search(r"SPDX-License-Identifier:\s*\|?\s*([^|\n]+?)\s*\|?\s*$",
                       head, re.M)
        if m2:
            found.add(m2.group(1))
        elif "Permission is hereby granted, free of charge" in head:
            found.add("MIT")
        elif "Apache License, Version 2.0" in head:
            found.add("Apache-2.0")
        else:
            unidentified += 1
    if not found:
        raise SystemExit(f"{pkg}: no licence id readable from deb — record it by hand")
    if unidentified:
        log(f"  note {pkg}: {unidentified} doc file(s) carry no licence id")
    return " / ".join(sorted(found))


# --------------------------------------------------------------- elf side --

class Dynstr:
    """Address-translated view of one ELF64 file, with checked .dynstr edits."""

    def __init__(self, blob: bytes):
        if blob[:4] != b"\x7fELF" or blob[4] != 2:
            raise SystemExit("not an ELF64 binary")
        if blob[5] != 1:
            raise SystemExit("not little-endian")
        self.b = bytearray(blob)
        e_phoff, = struct.unpack_from("<Q", self.b, 32)
        e_phentsize, e_phnum = struct.unpack_from("<HH", self.b, 54)
        self.loads, self.dyn = [], None
        for i in range(e_phnum):
            o = e_phoff + i * e_phentsize
            p_type, _, p_offset, p_vaddr, _, p_filesz, p_memsz = struct.unpack_from(
                SZ64, self.b, o
            )[:7]
            if p_type == PT_LOAD:
                self.loads.append((p_vaddr, p_offset, p_filesz))
            elif p_type == PT_DYNAMIC:
                self.dyn = (p_offset, p_filesz)
        if self.dyn is None:
            raise SystemExit("no PT_DYNAMIC")

    def v2o(self, va: int) -> int:
        for vaddr, off, filesz in self.loads:
            if vaddr <= va < vaddr + filesz:
                return off + (va - vaddr)
        raise SystemExit(f"vaddr {va:#x} not inside any PT_LOAD")

    def cstr(self, off: int) -> str:
        end = self.b.index(0, off)
        return self.b[off:end].decode("ascii", "replace")

    def entries(self):
        off, size = self.dyn
        for i in range(size // 16):
            tag, val = struct.unpack_from("<QQ", self.b, off + i * 16)
            if tag == 0:
                return
            yield tag, val, off + i * 16

    def strtab_off(self) -> int:
        for tag, val, _ in self.entries():
            if tag == 5:  # DT_STRTAB
                return self.v2o(val)
        raise SystemExit("no DT_STRTAB")

    def referenced_offsets(self) -> set[int]:
        """Every .dynstr offset the dynamic symbol table points at."""
        st_off, ent = 0, 24
        for tag, val, _ in self.entries():
            if tag == 6:  # DT_SYMTAB
                st_off = self.v2o(val)
            elif tag == 11:  # DT_SYMENT
                ent = val
        strtab = self.strtab_off()
        if not st_off or strtab <= st_off or not ent:
            return set()
        # No DT_SYMTABSZ exists, so bound .dynsym by the gap to .dynstr, which
        # is how every toolchain here lays them out, then clamp again so a
        # surprise ordering can never read past the end of the file.
        count = min((strtab - st_off) // ent, (len(self.b) - st_off) // ent)
        refs = set()
        for i in range(count):
            st_name, = struct.unpack_from("<I", self.b, st_off + i * ent)
            if st_name:
                refs.add(strtab + st_name)
        return refs


def rewrite_rodata(path: str) -> list[str]:
    """Shorten compile-time Termux paths in .rodata, NUL-padding the tail.

    Same invariant as the .dynstr rewrite: never lengthen, so no offset moves.
    A match only counts when the old text is followed by its own NUL, which is
    what distinguishes a real C string from a coincidental substring.
    """
    rules = RODATA_REWRITE.get(os.path.basename(path))
    if not rules:
        return []
    blob = bytearray(open(path, "rb").read())
    touched = []
    for old, new in rules:
        ob, nb = old.encode("ascii"), new.encode("ascii")
        if len(nb) >= len(ob):
            raise SystemExit(f"{path}: rodata '{new}' not shorter than '{old}'")
        hits, i = 0, blob.find(ob)
        while i != -1:
            if i + len(ob) < len(blob) and blob[i + len(ob)] == 0:
                blob[i : i + len(ob)] = nb + b"\x00" * (len(ob) - len(nb))
                hits += 1
            i = blob.find(ob, i + 1)
        if hits == 0:
            raise SystemExit(
                f"{os.path.basename(path)}: rodata '{old}' not found "
                f"(upstream changed?) — refusing to ship a noisy bash"
            )
        touched.append(f"rodata:{old}->{new}x{hits}")
    open(path, "wb").write(bytes(blob))
    return touched


def rewrite_elf(path: str) -> list[str]:
    elf = Dynstr(open(path, "rb").read())
    strtab = elf.strtab_off()
    safe_refs = elf.referenced_offsets()
    touched: list[str] = []
    planned: list[tuple[int, int, str]] = []

    for tag, val, _ in elf.entries():
        if tag not in DT:
            continue
        at = strtab + val
        old = elf.cstr(at)
        if tag in (15, 29):  # DT_RPATH / DT_RUNPATH: colon-separated list
            parts = [REWRITE.get(p, p) for p in old.split(":")]
            parts = list(dict.fromkeys(parts))  # collapse repeated dirs
            new = ":".join(parts)
        else:
            new = REWRITE.get(old)
        if new is None or new == old:
            continue
        if len(new) > len(old):
            raise SystemExit(
                f"{os.path.basename(path)}: '{new}' is longer than '{old}'"
            )
        planned.append((at, len(old), new))
        touched.append(f"{DT.get(tag, tag)}:{old}->{new}")

    # A shortened tail is NUL-padded; suffix merging may have parked another
    # string's start inside it. Refuse rather than corrupt .dynsym lookups.
    for at, oldlen, _ in planned:
        for ref in safe_refs:
            if at < ref < at + oldlen - 1:
                raise SystemExit(
                    f"{os.path.basename(path)}: .dynsym offset {ref} "
                    f"overlaps rewrite at {at}; aborting"
                )

    for at, oldlen, new in planned:
        enc = new.encode("ascii")
        pos = at
        elf.b[pos : pos + len(enc)] = enc
        pos += len(enc)
        elf.b[pos] = 0
        pos += 1
        while pos < at + oldlen:  # keep .dynstr size, and every offset, intact
            elf.b[pos] = 0
            pos += 1

    open(path, "wb").write(bytes(elf.b))
    return touched


# ------------------------------------------------------------- verification --

SYSTEM_LIBS = {"libc.so", "libm.so", "libdl.so", "liblog.so", "libz.so",
               "libstdc++.so", "libandroid.so", "libexpat.so", "libm.so"}


def verify(dst: str) -> None:
    """Re-read what we wrote: unresolved deps or leftover Termux paths are a
    boot-time failure we cannot see from a desktop build, so catch them here."""
    names = set(os.listdir(dst))
    problems: list[str] = []
    if not names & {"libbbmain.so", "libbash.so"}:
        problems.append("no executable shipped")
    for name in sorted(names):
        raw = open(os.path.join(dst, name), "rb").read()
        for old, _ in RODATA_REWRITE.get(name, []):
            ob = old.encode("ascii")
            i = raw.find(ob)
            while i != -1:
                if i + len(ob) < len(raw) and raw[i + len(ob)] == 0:
                    problems.append(f"{name}: rodata {old} still present")
                    break
                i = raw.find(ob, i + 1)
        elf = Dynstr(raw)
        strtab = elf.strtab_off()
        for tag, val, _ in elf.entries():
            if tag not in DT:
                continue
            s = elf.cstr(strtab + val)
            if "com.termux" in s:
                problems.append(f"{name}: unrewritten {DT[tag]} {s}")
            if tag == 1:  # DT_NEEDED
                if s not in names and s not in SYSTEM_LIBS:
                    problems.append(f"{name}: DT_NEEDED {s} ships nowhere")
            if tag in (15, 29) and s != "$ORIGIN":
                problems.append(f"{name}: runpath is {s!r}, expected $ORIGIN")
    if problems:
        for p in problems:
            log(f"  VERIFY FAIL {p}")
        raise SystemExit(f"verification failed for {dst}")
    log(f"  verify ok: {len(names)} files, deps closed, runpaths=$ORIGIN")


# ------------------------------------------------------------------ main ----

NOTICE = os.path.join(REPO, "android", "USERLAND_NOTICES.md")
MARKER = "<!-- generated: 由 tool/prepare_android_userland.py 覆写，勿手改 -->"


def write_notice(sections: list[tuple[str, str, int, list[dict]]]) -> None:
    """Record where the shipped ELF came from, next to the tree that holds it.

    jniLibs/ is an Android source set, so the notice deliberately lives one
    level up rather than in a directory AGP walks. GPL parts are redistributed
    here, which makes "which upstream build is this" a legal requirement, not
    just good hygiene -- and a hand-kept list is the kind that silently rots
    into a lie the next time this script is run.

    Takes every ABI packed in this run so one invocation writes one file: the
    generated region is replaced as a whole, which only works if it is written
    once. Appending per ABI would stack copies.
    """
    import hashlib
    import time

    if os.path.exists(NOTICE):
        # Split on MARKER, which is re-emitted below -- a marker that cannot be
        # found again turns every run into an append instead of a replace.
        head = open(NOTICE, encoding="utf-8").read().split(MARKER)[0]
    else:
        head = "# 内置 Android userland 出处与许可\n\n"
    out = [head.rstrip("\n"), "", MARKER, ""]
    for arch, abi, total, rows in sections:
        out += [
            f"- 归档时间：{time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime())} UTC",
            f"- 来源仓库：{REPOS[arch]}（Termux 官方 apt 源，dists/stable/main）",
            f"- 目标 ABI：{abi}",
            f"- 合计 {total / 1024 / 1024:.2f} MiB（解包后）",
            "",
            "| 包 | 版本 | 随包文件名 | deb SHA256 | 许可 |",
            "|---|---|---|---|---|",
        ]
        for r in rows:
            sha = hashlib.sha256(open(r["deb"], "rb").read()).hexdigest()
            out.append(
                f"| {r['pkg']} | {r['version']} | `{'`, `'.join(r['shipped'])}` "
                f"| `{sha}` | {r['license']} |"
            )
        out += [""]
    out += [
        "改写内容（见 tool/prepare_android_userland.py 文档字符串里的长度不变量）：",
        "",
        "* `DT_RUNPATH` 指到 `$ORIGIN`，`DT_NEEDED`/`DT_SONAME` 换成 `lib*.so` 形式；",
        "* bash 的 `.rodata` 里两个 Termux rc 路径改指向不存在的文件，",
        "  否则每个提示符都会重复一行 `Permission denied`。",
        "",
        "本文件按 ABI 分节，以上列出的就是随 APK 分发的全部 ABI。没打到的架构",
        "（如 32 位 armeabi-v7a）探测不到可执行程序，运行时会回落到",
        "`/system/bin/sh`；补一个 ABI 只要 `--arch arm`，代价是 universal APK 里",
        "多约 4 MiB（CI 用 `flutter build apk`，不做 ABI 分包）。",
        "",
        "## GPL 源码获取",
        "",
        "busybox（GPL-2.0）、bash 与 readline（GPL-3.0）、libiconv（LGPL-2.1/GPL-3.0",
        "双许可）以二进制形式随 APK 分发。对应源码按上表版本号从 Termux 构建链获取：",
        "",
        "* 打包配方与补丁：<https://github.com/termux/termux-packages/tree/master/packages>",
        "* 上游原始 tarball 版本与上表一致（busybox.net、gnu.org/software/bash 等）。",
        "",
        "本仓库如需移除该目录，整棵 `jniLibs/` 连同本文件一起删掉即可；运行时会探测",
        "失败并回落到 `/system/bin/sh`，终端功能不受影响。",
        "",
    ]
    with open(NOTICE, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))
    log(f"  notice -> {NOTICE}")


def main() -> int:
    ap = argparse.ArgumentParser()
    # arm/x86_64 stay opt-in: each ABI costs ~4 MiB unpacked, and any ABI we do
    # not ship falls back to /system/bin/sh at runtime.
    ap.add_argument("--arch", choices=sorted(ABI_OF), action="append",
                    default=None, help="default: aarch64")
    ap.add_argument("--cache", default=os.path.join(REPO, "build", "termux-cache"))
    ap.add_argument("--out", default=os.path.join(REPO, "android", "app", "src",
                                                  "main", "jniLibs"))
    args = ap.parse_args()
    os.makedirs(args.cache, exist_ok=True)

    sections: list[tuple[str, str, int, list[dict]]] = []
    for arch in args.arch or ["aarch64"]:
        abi = ABI_OF[arch]
        dst = os.path.join(args.out, abi)
        os.makedirs(dst, exist_ok=True)
        log(f"=== {arch} -> jniLibs/{abi} ===")
        total = 0
        rows: list[dict] = []
        idx = parse_index(fetch_index(arch, args.cache))
        for pkg, items in TARGETS.items():
            files = get_files(pkg, arch, args.cache)
            shipped = []
            for sub, rename in items:
                if sub not in files:
                    raise SystemExit(f"{pkg}: no {sub} (version drift?)")
                name = rename or os.path.basename(sub)
                path = os.path.join(dst, name)
                open(path, "wb").write(files[sub])
                os.chmod(path, 0o755)
                touched = rewrite_elf(path) + rewrite_rodata(path)
                size = os.path.getsize(path)
                total += size
                shipped.append(name)
                log(f"  {name:20} {size/1024:7.0f}K  "
                    f"{' '.join(touched) if touched else '(no rewrite)'}")
            rows.append({
                "pkg": pkg,
                "version": idx[pkg]["Version"],
                "deb": os.path.join(args.cache, f"{pkg}.{arch}.deb"),
                "shipped": shipped,
                "license": license_id(pkg, arch, args.cache),
            })
        log(f"  total {total/1024/1024:.2f} MiB unpacked into {abi}")
        verify(dst)
        sections.append((arch, abi, total, rows))
    write_notice(sections)
    packed = {s[1] for s in sections}
    if os.path.isdir(args.out):
        stray = [d for d in sorted(os.listdir(args.out))
                 if d not in packed and os.path.isfile(
                     os.path.join(args.out, d, "libbbmain.so"))]
        if stray:
            log(f"  WARNING: jniLibs/{', '.join(stray)} exists but this run did"
                f" not write its notice section -- re-run with --arch for those"
                f" too, or GPL provenance for them is now undocumented")
    return 0


if __name__ == "__main__":
    sys.exit(main())
