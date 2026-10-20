"""
sig_probe.py — read a Mach-O code signature straight out of a .tipa.

Answers the question that decides whether TrollStore can launch the app, without
a Mac and without guessing:

  * is there a code signature at all   (LC_CODE_SIGNATURE)
  * what identifier does it claim      (CodeDirectory)
  * is there a CMS blob                (superblob slot type 0x10000)

The CMS slot is the one that matters. TrollStore's install path leans on
CoreTrust, and an ad-hoc `codesign -s -` signature carries entitlements but no
CMS structure. `platform-application` being present is not enough by itself — the
signature has to be shaped like one CoreTrust will look at.

Blob layout (Apple's codesign.h):

    SuperBlob   magic 0xfade0cc0  big-endian length, count
                [ (type:u32, offset:u32) * count ]
    each index  -> Blob { magic:u32, length:u32 } + payload

    type 0      CodeDirectory   (0xfade0c02)
    type 2      Requirements    (0xfade0c01)
    type 5      Entitlements    (0xfade7171)
    type 0x10000 CMS wrapper    (0xfade0b01)
"""

import plistlib
import struct
import sys
import zipfile

LC_CODE_SIGNATURE = 0x1D

BLOB_NAMES = {
    0x00000: "CodeDirectory",
    0x00001: "Info.plist slot",
    0x00002: "Requirements",
    0x00003: "ResourceDir",
    0x00005: "Entitlements",
    0x10000: "CMS (detached signature)",
    0x10001: "Identification",
    0x10002: "Ticket",
}


def macho_code_signature(data: bytes):
    """Return (offset, size) of the code signature region, or None."""
    magic = int.from_bytes(data[0:4], "little")
    if magic not in (0xFEEDFACF, 0xFEEDFACE):
        raise ValueError(f"not a Mach-O (magic 0x{magic:08X})")

    is64 = magic == 0xFEEDFACF
    sizeofcmds_off = 20 if is64 else 16
    ncmds = int.from_bytes(data[16:20], "little")
    sizeofcmds = int.from_bytes(data[sizeofcmds_off:sizeofcmds_off + 4], "little")

    header_size = 32 if is64 else 28
    pos = header_size
    end = header_size + sizeofcmds

    while pos < end:
        cmd = int.from_bytes(data[pos:pos + 4], "little")
        cmdsize = int.from_bytes(data[pos + 4:pos + 8], "little")
        if cmdsize <= 0:
            break
        if cmd == LC_CODE_SIGNATURE:
            dataoff = int.from_bytes(data[pos + 8:pos + 12], "little")
            datasize = int.from_bytes(data[pos + 12:pos + 16], "little")
            return dataoff, datasize
        pos += cmdsize
    return None


def parse_superblob(blob: bytes):
    magic = int.from_bytes(blob[0:4], "big")
    if magic != 0xFADE0CC0:
        raise ValueError(f"not a SuperBlob (magic 0x{magic:08X})")
    length = int.from_bytes(blob[4:8], "big")
    count = int.from_bytes(blob[8:12], "big")
    entries = []
    for i in range(count):
        base = 12 + i * 8
        btype = int.from_bytes(blob[base:base + 4], "big")
        boff = int.from_bytes(blob[base + 4:base + 8], "big")
        if boff + 8 > len(blob):
            continue
        bmagic = int.from_bytes(blob[boff:boff + 4], "big")
        blen = int.from_bytes(blob[boff + 4:boff + 8], "big")
        entries.append((btype, boff, bmagic, blen))
    return length, entries


def describe(name: str, data: bytes) -> bool:
    """Print what the signature contains. Returns True if a CMS slot is present."""
    try:
        found = macho_code_signature(data)
    except ValueError as exc:
        print(f"{name:46} {exc}")
        return False

    if not found:
        print(f"{name:46} NO LC_CODE_SIGNATURE")
        return False

    off, size = found
    blob = data[off:off + size]
    try:
        _length, entries = parse_superblob(blob)
    except ValueError as exc:
        print(f"{name:46} signature unreadable: {exc}")
        return False

    types = {t for (t, _o, _m, _l) in entries}
    labels = ", ".join(BLOB_NAMES.get(t, f"0x{t:X}") for t in sorted(types))
    has_cms = 0x10000 in types

    ident = ""
    for (btype, boff, _bm, blen) in entries:
        if btype == 0:
            body = blob[boff:boff + blen]
            # CodeDirectory: magic, length, version, flags, hashOffset, identOffset...
            try:
                ident_off = int.from_bytes(body[20:24], "big")
                ident = body[ident_off:body.index(b"\0", ident_off)].decode("utf-8", "replace")
            except Exception:
                pass
            break

    ents = []
    for (btype, boff, _bm, blen) in entries:
        if btype == 5:
            body = blob[boff:boff + blen]
            payload = body[8:]
            try:
                d = plistlib.loads(payload)
                ents = sorted(d.keys())
            except Exception:
                try:
                    d = plistlib.loads(payload[8:])
                    ents = sorted(d.keys())
                except Exception:
                    pass

    status = "CMS present" if has_cms else "NO CMS -> CoreTrust will reject"

    # A CMS slot can exist and still be worthless: `codesign -s -` writes the
    # wrapper with zero bytes of payload, and that is what CoreTrust rejects.
    cms_payload = 0
    for (btype, boff, _bm, blen) in entries:
        if btype == 0x10000:
            cms_payload = max(0, blen - 8)
            break

    if has_cms and cms_payload < 512:
        status = (f"EMPTY CMS ({cms_payload} bytes) -> CoreTrust will reject; "
                  f"re-sign with ldid")
        has_cms = False
    elif has_cms:
        status = f"CMS present ({cms_payload} bytes of fake chain)"

    print(f"{name:46} {status}")
    print(f"   id={ident!r} blobs=[{labels}] entitlements={len(ents)}")
    if ents:
        keep = [e for e in ents if e.startswith("platform") or "security" in e]
        print(f"   key ones: {keep[:4]}")
    print(f"   size={size} bytes")
    return has_cms


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: sig_probe.py <file.tipa | mach-o>")
        return 2

    target = sys.argv[1]

    # A bare Mach-O is the cheap case: this is what the signer self-test feeds
    # it, so a signer that cannot produce a CMS fails two minutes into a run
    # instead of after a full build.
    if not zipfile.is_zipfile(target):
        data = open(target, "rb").read()
        ok = describe(target.rsplit("/", 1)[-1], data)
        print()
        print("VERDICT:", "CMS present" if ok else "no usable CMS")
        return 0 if ok else 1

    z = zipfile.ZipFile(target)
    names = z.namelist()

    binaries = []
    for n in names:
        if not n.startswith("Payload/"):
            continue
        parts = n.split("/")
        if len(parts) == 3 and parts[2] == "Minis":
            binaries.append(n)
    for n in names:
        if "/PlugIns/" in n and n.count("/") == 4 and not n.endswith("/"):
            binaries.append(n)

    print(f"probing {len(binaries)} binaries in {target}\n")
    cms_count = 0
    for n in binaries:
        with z.open(n) as fh:
            head = fh.read(4)
            if int.from_bytes(head, "little") not in (0xFEEDFACF, 0xFEEDFACE):
                continue
            data = z.read(n)
        if describe(n.replace("Payload/", ""), data):
            cms_count += 1

    print()
    if cms_count == 0:
        print("VERDICT: no binary carries a usable CMS blob. CoreTrust has nothing")
        print("to evaluate and the app is killed at exec with no useful log.")
        return 1
    print(f"VERDICT: {cms_count} binary/binaries carry a usable CMS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
