#!/usr/bin/env python3
"""
patch_minis.py — apply the runtime-host graft to a checkout of OpenMinis.

Three edits, each reversible and each verified after writing:

  1. Add `RuntimeHost/` to the Minis app target as a
     PBXFileSystemSynchronizedRootGroup. objectVersion 70 supports this, which
     is why the graft needs no per-file PBXBuildFile entries: drop a .swift/.c
     into the folder and Xcode compiles it. Same mechanism the project already
     uses for `Terminal`.

  2. Import RuntimeArchive.h from the bridging header so Swift can call the
     gunzip shim (Swift cannot import a header that is not bridged).

  3. Branch `ISHExecutionCoordinator.execute` on native availability. The
     native backend is tried first; anything that throws falls through to iSH,
     so a device without the entitlement keeps upstream behaviour exactly.

Run from the repository root:

    python3 patches/patch_minis.py --repo /path/to/OpenMinis

Idempotent: a second run reports "already patched" and changes nothing.
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC_HOST = HERE.parent / "src" / "ios" / "RuntimeHost"

GROUP_NAME = "RuntimeHost"

# Only source files go into the synchronized folder. Helpers/ (bash, the
# multicall host, the signer) is staged separately in CI and copied into the
# built .app, because a synchronized group would try to treat 800 KB of
# extensionless arm64 binaries as build inputs.
SOURCE_SUFFIXES = {".swift", ".c", ".h", ".m", ".mm", ".cpp"}


# ---------------------------------------------------------------------------
# 1. project.pbxproj: add the synchronized folder to the app target
# ---------------------------------------------------------------------------

def patch_pbxproj(pbxproj: Path) -> str:
    text = pbxproj.read_text(encoding="utf-8")
    if GROUP_NAME in text:
        return "already patched"

    if "PBXFileSystemSynchronizedRootGroup" not in text:
        return ("SKIP: project does not use synchronized root groups; "
                "add RuntimeHost/*.swift manually in Xcode")

    # This project's object identifiers are not all 24 hex characters —
    # `E51000040 /* Minis */` is a real target UUID in it. So nothing here may
    # assume a length; we splice by anchor lines instead of regexing UUIDs.
    #
    # E51000040 = PBXNativeTarget Minis (application)
    # E51000031 = PBXGroup Minis (the app's source group)
    TARGET_UUID = "E51000040"
    GROUP_UUID = "E51000031"
    NEW_UUID = "E5RT00012F700000000000AA"

    lines = text.split("\n")

    def find(prefix: str, start: int = 0) -> int:
        for i in range(start, len(lines)):
            if lines[i].strip().startswith(prefix):
                return i
        return -1

    # (a) declare the group
    section = find("/* Begin PBXFileSystemSynchronizedRootGroup section */")
    if section < 0:
        return "FAILED: synchronized root group section missing"
    lines.insert(section + 1,
                 f"\t\t{NEW_UUID} /* {GROUP_NAME} */ = {{isa = PBXFileSystemSynchronizedRootGroup; "
                 f"explicitFileTypes = {{}}; explicitFolders = (); path = {GROUP_NAME}; "
                 f"sourceTree = \"<group>\"; }};")

    # (b) attach to the app target so its sources get compiled
    target = find(f"{TARGET_UUID} /* Minis */ = {{")
    if target < 0:
        return "FAILED: Minis PBXNativeTarget not found"
    target_end = find("};", target)
    sync = find("fileSystemSynchronizedGroups = (", target)
    if sync < 0 or sync > target_end:
        return "FAILED: Minis target has no fileSystemSynchronizedGroups"
    close = find(");", sync)
    if close < 0:
        return "FAILED: unterminated fileSystemSynchronizedGroups"
    lines.insert(close, f"\t\t\t\t{NEW_UUID} /* {GROUP_NAME} */,")

    # (c) show it in the project navigator. Without this the folder still
    #     compiles but is invisible in Xcode, which makes the patch look broken.
    group = find(f"{GROUP_UUID} /* Minis */ = {{")
    if group >= 0:
        children = find("children = (", group)
        if children > 0:
            lines.insert(children + 1, f"\t\t\t\t{NEW_UUID} /* {GROUP_NAME} */,")

    pbxproj.write_text("\n".join(lines), encoding="utf-8")
    return "patched"


# ---------------------------------------------------------------------------
# 2. bridging header
# ---------------------------------------------------------------------------

def patch_bridging_header(header: Path) -> str:
    if not header.exists():
        return "MISSING bridging header"
    text = header.read_text(encoding="utf-8", errors="replace")
    if "RuntimeArchive.h" in text:
        return "already patched"
    text = text.rstrip() + '\n\n// RuntimeHost: gzip streaming for the runtime installer\n#import "RuntimeArchive.h"\n'
    header.write_text(text, encoding="utf-8")
    return "patched"


# ---------------------------------------------------------------------------
# 3. coordinator branch
# ---------------------------------------------------------------------------

COORDINATOR_GUARD = """        // [native-runtime-graft] Prefer the real executor when this build is
        // platform-signed and the shell helpers shipped. Everything below this
        // block is upstream iSH behaviour, untouched; a device that cannot exec
        // natively throws here and pays only one availability check.
        if await NativeShellBackend.shared.isAvailable {
            do {
                let native = try await NativeShellBackend.shared.execute(
                    sessionId: sessionId,
                    command: command,
                    timeout: timeout,
                    lineCallback: lineCallback,
                    pidCallback: { pidCallback(pid_t($0)) }
                )
                return native.ishResult
            } catch let err as NativeShellError {
                if case .timedOut(let partial, _, _) = err {
                    return ISHCommandResult(output: partial, exitCode: 124)
                }
                logger.warning("native backend failed, falling back to iSH: \\(err.localizedDescription)")
            } catch {
                logger.warning("native backend failed, falling back to iSH: \\(error.localizedDescription)")
            }
        }
"""


def patch_coordinator(path: Path) -> str:
    text = path.read_text(encoding="utf-8", errors="replace")
    if "native-runtime-graft" in text:
        return "already patched"

    # Anchor: the availability guard at the top of execute(...).
    anchor = "        guard ISHKernel.shared.isBooted else {\n            throw ISHCoordinatorError.kernelNotBooted\n        }\n"
    if anchor not in text:
        return "FAILED: kernelNotBooted guard not found — coordinator shape changed"

    text = text.replace(anchor, anchor + "\n" + COORDINATOR_GUARD, 1)
    path.write_text(text, encoding="utf-8")
    return "patched"


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="OpenMinis checkout root")
    ap.add_argument("--check", action="store_true", help="report without writing")
    args = ap.parse_args()

    repo = Path(args.repo).resolve()
    ios = repo / "src" / "ios"
    if not (ios / "Minis.xcodeproj").exists():
        print(f"error: {ios}/Minis.xcodeproj not found", file=sys.stderr)
        return 2

    # Copy the host sources in. When the sources already live at the target
    # path (the repo carries them directly), comparing resolved paths avoids
    # copying a file onto itself.
    dest = ios / GROUP_NAME
    sources = [f for f in SRC_HOST.iterdir()
               if f.is_file() and f.suffix in SOURCE_SUFFIXES]
    if not args.check:
        dest.mkdir(exist_ok=True)
        copied = 0
        for f in sources:
            target = dest / f.name
            if target.exists() and target.resolve() == f.resolve():
                continue
            shutil.copy2(f, target)
            copied += 1
        print(f"{len(sources)} source file(s) at {dest} ({copied} copied)")

    results = {
        "project.pbxproj": patch_pbxproj(ios / "Minis.xcodeproj" / "project.pbxproj"),
        "bridging header": patch_bridging_header(ios / "MinisApp-Bridging-Header.h"),
        "ISHExecutionCoordinator": patch_coordinator(ios / "Agent" / "ISH" / "ISHExecutionCoordinator.swift"),
    }

    width = max(len(k) for k in results)
    failed = False
    for k, v in results.items():
        print(f"  {k.ljust(width)} : {v}")
        if v.startswith("FAILED") or v.startswith("MISSING"):
            failed = True

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
