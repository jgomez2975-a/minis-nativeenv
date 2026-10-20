"""
verify_tipa.py — inspect a packaged .tipa without a Mac.

Checks the things that decide whether TrollStore will install it and whether the
grafted runtime is actually inside:

  * archive shape      Payload/<App>.app only, nothing at the root
  * bundle identity    Info.plist parses, id and executable present
  * helpers            bash.real / ca-filetool / codex-sign shipped and non-trivial
  * architecture       main binary is arm64
  * graft presence     RuntimeHost strings are in the binary, so the runtime
                       backend was compiled in and not dropped by the linker

Usage: python3 verify_tipa.py path/to/file.tipa
"""

import plistlib
import sys
import zipfile


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: verify_tipa.py <file.tipa>")
        return 2
    path = sys.argv[1]
    z = zipfile.ZipFile(path)
    names = z.namelist()
    problems = []

    print(f"file            : {path}")
    print(f"entries         : {len(names)}")
    print(f"uncompressed    : {sum(i.file_size for i in z.infolist())/1e6:.1f} MB")

    tops = sorted({n.split("/")[0] for n in names})
    print(f"top-level       : {tops}")
    if tops != ["Payload"]:
        problems.append(f"unexpected top-level entries: {tops}")

    apps = sorted({n.split("/")[1] for n in names
                   if n.startswith("Payload/") and n.count("/") >= 1})
    print(f"bundles         : {apps}")
    app = None
    for candidate in apps:
        if candidate.endswith(".app"):
            app = candidate
            break
    if not app:
        print("FAILED: no .app inside Payload")
        return 1

    prefix = f"Payload/{app}/"
    try:
        info = plistlib.loads(z.read(prefix + "Info.plist"))
    except KeyError:
        print("FAILED: no Info.plist")
        return 1

    exe = info.get("CFBundleExecutable", "")
    print(f"bundle id       : {info.get('CFBundleIdentifier')}")
    print(f"executable      : {exe}")
    print(f"version         : {info.get('CFBundleShortVersionString')} ({info.get('CFBundleVersion')})")
    print(f"min OS          : {info.get('MinimumOSVersion')}")
    if not exe:
        problems.append("CFBundleExecutable missing")

    # Helpers: the whole reason the environment works.
    expected = {
        "Helpers/bash.real": 700_000,
        "Helpers/ca-filetool": 100_000,
        "Helpers/codex-sign": 1_000_000,
    }
    helpers = [n for n in names if "/Helpers/" in n]
    print(f"helpers         : {len(helpers)} entries")
    for rel, minimum in expected.items():
        full = prefix + rel
        if full not in names:
            problems.append(f"missing helper {rel}")
            continue
        size = z.getinfo(full).file_size
        state = "ok" if size >= minimum else f"TOO SMALL ({size})"
        print(f"  {rel:26} {size:>9} bytes  {state}")
        if size < minimum:
            problems.append(f"{rel} is only {size} bytes")

    main = prefix + exe
    if main not in names:
        print(f"FAILED: main binary {main} missing")
        return 1
    data = z.read(main)
    print(f"main binary     : {len(data)/1e6:.1f} MB")
    cputype = int.from_bytes(data[4:8], "little")
    if cputype == 0x0100000C:
        print("arch            : arm64")
    else:
        print(f"arch            : cputype 0x{cputype:X} (expected 0x100000C arm64)")
        problems.append(f"unexpected cputype 0x{cputype:X}")

    # The graft has to be *in* the binary, not merely in the sources. Needles are
    # chosen to be literals the compiler cannot merge away, and to avoid ones
    # built by interpolation — `"Helpers/\(name)"` produces no "Helpers/codex-sign"
    # string, so asking for that literal gives a false negative.
    needles = [
        b"Helpers/bash",
        b"platform-application",
        b"native exec unavailable",
        b"could not be loaded",
        b"path escape",
        b"required_paths",
        b"theos/bin",
        b"sign_paths from the runtime descriptor",
    ]
    print("graft markers in binary:")
    for needle in needles:
        present = needle in data
        print(f"  {needle.decode():38} {'present' if present else 'ABSENT'}")
        if not present:
            problems.append(f"graft marker missing: {needle.decode()}")

    print()
    if problems:
        print(f"FAILED — {len(problems)} problem(s):")
        for p in problems:
            print("  *", p)
        return 1
    print("PASSED — archive shape, bundle identity, helpers and graft all present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
