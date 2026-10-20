#!/usr/bin/env python3
"""
make_tipa.py — turn a built .app into a TrollStore-installable .tipa.

A .tipa is an .ipa (zip with a Payload/ directory) whose main binary carries
platform entitlements and a signature CoreTrust will accept. Order of
operations is the whole game:

  1. strip App Store artefacts           — _CodeSignature, embedded.mobileprovision
  2. thin to arm64                        — a fat binary from an archive bloats the
                                            tipa and TrollStore only loads arm64
  3. sign nested code first, innermost out — frameworks, then appex, then the app.
                                            Signing the app before a nested bundle
                                            invalidates the outer signature.
  4. sign the app LAST with entitlements  — including platform-application
  5. verify                               — codesign --verify, and dump the
                                            entitlements back to prove the step
                                            actually landed
  6. zip                                  — Payload/ only; no extras at the root

ldid is preferred over `codesign -s -` because it writes a fake CMS blob that
CoreTrust accepts for platform-only entitlements; a plain ad-hoc codesign can be
rejected at launch on some iOS builds. If ldid is missing the script falls back
to codesign and says so.

Usage:
    python3 scripts/make_tipa.py --app path/to/Minis.app \
                                 --entitlements entitlements/Minis-TrollStore.entitlements \
                                 --out dist/Minis.tipa
"""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path


# ---------------------------------------------------------------------------

def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=False) if not check \
        else subprocess.run(cmd, capture_output=True, text=True, check=True)


def which(name: str) -> str | None:
    return shutil.which(name)


# ---------------------------------------------------------------------------
# 1. clean
# ---------------------------------------------------------------------------

def clean_app(app: Path) -> None:
    for junk in ("_CodeSignature", "embedded.mobileprovision", "SC_Info"):
        target = app / junk
        if target.exists():
            if target.is_dir():
                shutil.rmtree(target)
            else:
                target.unlink()
            print(f"  removed {junk}")

    # Nested bundles carry their own _CodeSignature too.
    for pattern in ("**/_CodeSignature", "**/embedded.mobileprovision"):
        for path in app.glob(pattern):
            if pattern.startswith("**/_Code") and path.is_dir():
                shutil.rmtree(path, ignore_errors=True)
            elif path.is_file():
                path.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# 2. thin
# ---------------------------------------------------------------------------

def thin_binaries(app: Path) -> None:
    lipo = which("lipo")
    if not lipo:
        print("  lipo unavailable — skipping thin step")
        return

    binaries = [app / app.stem]
    binaries += [p for p in app.glob("Frameworks/*.framework/*")
                 if p.is_file() and not p.name.endswith(".plist")]
    binaries += [p for p in app.glob("PlugIns/*.appex/*")
                 if p.is_file() and not p.name.endswith(".plist")]
    binaries += [p for p in app.glob("Frameworks/*.dylib")]

    for binary in binaries:
        if not binary.is_file():
            continue
        info = run([lipo, "-info", str(binary)], check=False).stdout
        # `lipo -info` prints "Non-fat file: … is architecture: arm64" for a thin
        # binary and a space-separated architecture list for a fat one. Only a
        # fat file with an arm64 slice needs work; anything else is left alone.
        if "Non-fat file" in info or "arm64" not in info:
            continue
        architectures = info.rsplit("are:", 1)[-1].split() if "are:" in info else []
        if len(architectures) <= 1:
            continue
        tmp = binary.with_name(binary.name + ".thin")
        result = run([lipo, str(binary), "-thin", "arm64", "-output", str(tmp)], check=False)
        if result.returncode == 0 and tmp.exists():
            tmp.chmod(binary.stat().st_mode)
            tmp.replace(binary)
            print(f"  thinned {binary.relative_to(app)}")
        else:
            print(f"  WARNING: could not thin {binary.relative_to(app)}: {result.stderr.strip()[:160]}")


# ---------------------------------------------------------------------------
# 3/4. sign
# ---------------------------------------------------------------------------

class Signer:
    """
    Picks a signer that demonstrably works, rather than the first one on PATH.

    Three candidates exist and they are not interchangeable:

      * ldid 2.1.5 (Homebrew) — exits 0 while writing a signature that current
        `codesign` reports as "code object is not signed at all".
      * ProcursusTeam/ldid — the fork the TrollStore tooling uses, but its
        current HEAD does not compile against OpenSSL 3.
      * codesign — always present, always embeds the entitlements blob, no CMS.

    So each candidate is tried on a throwaway copy of a real Mach-O, and one
    that cannot put `platform-application` into a signature that reads back is
    rejected here instead of 20 minutes into a build.
    """

    def __init__(self, entitlements: Path | None = None) -> None:
        self.codesign = which("codesign")
        self.entitlements = entitlements

        candidates = []
        for candidate in ("/usr/local/bin/ldid", which("ldid")):
            if candidate and Path(candidate).exists() and candidate not in candidates:
                candidates.append(candidate)

        self.ldid = None
        for candidate in candidates:
            if self._verify(candidate, via_ldid=True):
                self.ldid = candidate
                print(f"  signer: ldid ({candidate})")
                return
            print(f"  rejected signer: {candidate} (signature does not read back)")

        if self.codesign and self._verify(self.codesign, via_ldid=False):
            print("  signer: codesign (ad-hoc, entitlements embedded)")
            return
        if self.codesign:
            # Even without a readable read-back, codesign is the only remaining
            # option; say so loudly rather than refusing to package.
            print("  WARNING: codesign could not be verified; packaging anyway")
            return

        raise SystemExit("error: no working signer (tried ldid and codesign)")

    def _verify(self, tool: str, via_ldid: bool) -> bool:
        """Sign a temp copy and read the entitlement back. Cheapest real test."""
        import tempfile

        if not self.entitlements or not self.entitlements.exists():
            return False
        probe_src = Path("/bin/echo")
        if not probe_src.exists():
            return False

        try:
            with tempfile.TemporaryDirectory() as td:
                probe = Path(td) / "probe"
                shutil.copy2(probe_src, probe)
                if via_ldid:
                    cmd = [tool, f"-S{self.entitlements}", str(probe)]
                else:
                    cmd = [tool, "--force", "--sign", "-", "--timestamp=none",
                           "--entitlements", str(self.entitlements), str(probe)]
                if subprocess.run(cmd, capture_output=True).returncode != 0:
                    return False

                dump = subprocess.run(
                    [which("codesign") or "codesign", "-d", "--entitlements", ":-",
                     str(probe)],
                    capture_output=True, text=True,
                    encoding="utf-8", errors="replace")
                return "platform-application" in (dump.stdout + dump.stderr)
        except Exception:
            return False

    def sign(self, target: Path, entitlements: Path | None = None) -> None:
        if self.ldid:
            cmd = [self.ldid]
            cmd.append(f"-S{entitlements}" if entitlements else "-S")
            cmd.append(str(target))
        else:
            cmd = [self.codesign, "--force", "--sign", "-", "--timestamp=none"]
            if entitlements:
                cmd += ["--entitlements", str(entitlements)]
            cmd.append(str(target))
        result = run(cmd, check=False)
        if result.returncode != 0:
            raise SystemExit(
                f"error: signing failed for {target}\n{result.stdout}\n{result.stderr}")


def sign_bundle(app: Path, entitlements: Path, signer: Signer) -> None:
    # Innermost first. Every Mach-O that the loader will map needs a signature.
    frameworks = sorted(app.glob("Frameworks/*.framework"), key=lambda p: len(p.parts), reverse=True)
    for fw in frameworks:
        binary = fw / fw.stem
        if binary.exists():
            signer.sign(binary)
            print(f"  signed {binary.relative_to(app)}")

    for dylib in app.glob("Frameworks/*.dylib"):
        signer.sign(dylib)
        print(f"  signed {dylib.relative_to(app)}")

    for appex in sorted(app.glob("PlugIns/*.appex")):
        # an appex keeps its own entitlements if it shipped one; otherwise adhoc
        appex_ent = appex / "Entitlements.plist"
        binary = appex / appex.stem
        if not binary.exists():
            info = plistlib.loads((appex / "Info.plist").read_bytes())
            binary = appex / info["CFBundleExecutable"]
        signer.sign(binary, appex_ent if appex_ent.exists() else None)
        print(f"  signed {binary.relative_to(app)}")

    # Main binary last, with the platform entitlements.
    info = plistlib.loads((app / "Info.plist").read_bytes())
    main_binary = app / info["CFBundleExecutable"]
    signer.sign(main_binary, entitlements)
    print(f"  signed {main_binary.relative_to(app)} (with entitlements)")


# ---------------------------------------------------------------------------
# 5. verify
# ---------------------------------------------------------------------------

def verify(app: Path, entitlements: Path) -> None:
    info = plistlib.loads((app / "Info.plist").read_bytes())
    main_binary = app / info["CFBundleExecutable"]

    expected = plistlib.loads(entitlements.read_bytes())
    codesign = which("codesign")
    if codesign:
        dump = run([codesign, "-d", "--entitlements", ":-", str(main_binary)], check=False)
        # codesign writes entitlements to stderr on some versions; check both.
        blob = dump.stdout + dump.stderr
        missing = [k for k in expected if k not in blob]
        if missing:
            print(f"  WARNING: entitlements not visible in signature: {missing}")
        else:
            print(f"  verified {len(expected)} entitlements present")

        ver = run([codesign, "--verify", "--deep", "--strict", str(app)], check=False)
        if ver.returncode != 0:
            print(f"  WARNING: codesign --verify returned {ver.returncode}\n{ver.stderr[:800]}")
        else:
            print("  codesign --verify --deep --strict: OK")
    else:
        print("  codesign unavailable — skipping verification")


# ---------------------------------------------------------------------------
# 6. zip
# ---------------------------------------------------------------------------

def make_zip(app: Path, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    out.unlink(missing_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        payload = Path(tmp) / "Payload"
        payload.mkdir()
        # copy2 keeps symlinks and modes; a naive copytree would flatten them
        target = payload / app.name
        shutil.copytree(app, target, symlinks=True, copy_function=shutil.copy2)

        if which("zip"):
            # -y preserves symlinks, -r recursive, -q quiet.
            #
            # cwd matters: the archive members must be `Payload/...` at the root
            # of the zip, and `zip` resolves its argument against the process
            # working directory, not against anything it is told separately.
            # Without cwd the command found no Payload directory and exited 12
            # ("nothing to do") after the whole build had succeeded.
            result = subprocess.run(
                ["zip", "-qry", str(out.resolve()), "Payload"],
                cwd=str(tmp), capture_output=True, text=True,
                encoding="utf-8", errors="replace")
            if result.returncode != 0:
                raise SystemExit(
                    f"error: zip failed ({result.returncode})\n"
                    f"{result.stdout}\n{result.stderr}")
        else:
            with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
                for root, _dirs, files in os.walk(payload):
                    for name in files:
                        full = Path(root) / name
                        zf.write(full, full.relative_to(tmp))
    print(f"  wrote {out} ({out.stat().st_size / 1e6:.1f} MB)")


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", required=True, type=Path)
    ap.add_argument("--entitlements", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--skip-signing", action="store_true",
                    help="package only; used to validate the zip/cleanup path "
                         "on a host without ldid/codesign")
    args = ap.parse_args()

    app = args.app.resolve()
    if not app.is_dir():
        print(f"error: {app} is not a directory", file=sys.stderr)
        return 2

    print(f"[1/6] cleaning {app.name}")
    clean_app(app)

    print("[2/6] thinning to arm64")
    thin_binaries(app)

    if args.skip_signing:
        print("[3/6][4/6][5/6] signing/verify skipped (--skip-signing)")
    else:
        print("[3/6] signing nested code")
        signer = Signer(args.entitlements.resolve())
        print(f"  signer: {'ldid' if signer.ldid else 'codesign (fallback)'}")

        print("[4/6] signing app with entitlements")
        sign_bundle(app, args.entitlements.resolve(), signer)

        print("[5/6] verifying")
        verify(app, args.entitlements.resolve())

    print("[6/6] packaging")
    make_zip(app, args.out.resolve())

    # Prove the archive has the shape TrollStore expects before handing it back.
    with zipfile.ZipFile(args.out) as zf:
        names = zf.namelist()
    top = {n.split("/")[0] for n in names}
    if top != {"Payload"}:
        print(f"  ERROR: unexpected top-level entries: {sorted(top)}", file=sys.stderr)
        return 1
    info_plists = [n for n in names if n.endswith("/Info.plist") and n.count("/") == 2]
    if not info_plists:
        print("  ERROR: no Payload/<X>.app/Info.plist in archive", file=sys.stderr)
        return 1
    print(f"  structure OK: {len(names)} entries, app = {info_plists[0].split('/')[1]}")

    print("done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
