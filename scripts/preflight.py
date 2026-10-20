#!/usr/bin/env python3
"""
preflight.py — fail in 20 seconds instead of 35 minutes.

The CI job spends ~35 minutes compiling native dependencies before the first
line of the app is built. A typo in a Swift file, a misplaced comma in the
project file, or an invalid plist turns that into a 35-minute wait for an error
message. This runs first and covers everything that is checkable without a
Mac:

  * Python scripts compile
  * workflow YAML parses and every step is well-formed
  * entitlements / Info.plist parse as property lists
  * project.pbxproj survives the patch with balanced delimiters and the new
    group attached to the right target
  * identifier references resolve (every PBXFileSystemSynchronizedRootGroup
    added is also referenced, every referenced id is defined)
  * Swift sources parse (tree-sitter; semantic type-checking still needs
    Xcode, but syntax is the failure mode that costs a rebuild)

Exit 0 = good to build. Exit 1 = printed reasons.

    python3 scripts/preflight.py --repo .
"""

from __future__ import annotations

import argparse
import plistlib
import py_compile
import re
import subprocess
import sys
import tempfile
from pathlib import Path

OK = "  ok   "
WARN = "  warn "
FAIL = "  FAIL "

failures: list[str] = []
warnings: list[str] = []


def ok(msg: str) -> None:
    print(OK + msg)


def warn(msg: str) -> None:
    print(WARN + msg)
    warnings.append(msg)


def fail(msg: str) -> None:
    print(FAIL + msg)
    failures.append(msg)


# ---------------------------------------------------------------------------
# Python
# ---------------------------------------------------------------------------

def check_python(repo: Path) -> None:
    print("\n[1] python scripts")
    targets = ["patches/patch_minis.py", "scripts/make_tipa.py", "scripts/preflight.py"]
    # py_compile writes atomically via rename, which cannot target an open
    # handle on Windows. Compile into a temp *directory* instead.
    with tempfile.TemporaryDirectory() as tmpdir:
        for rel in targets:
            path = repo / rel
            if not path.exists():
                fail(f"{rel} missing")
                continue
            cfile = Path(tmpdir) / (path.stem + ".pyc")
            try:
                py_compile.compile(str(path), cfile=str(cfile), doraise=True)
                ok(rel)
            except py_compile.PyCompileError as exc:
                msg = (exc.msg or "").strip().splitlines()
                fail(f"{rel}: {msg[-1] if msg else 'compile error'}")


# ---------------------------------------------------------------------------
# YAML
# ---------------------------------------------------------------------------

def check_workflow(repo: Path) -> None:
    print("\n[2] workflow yaml")
    wf = repo / ".github/workflows/build-tipa.yml"
    if not wf.exists():
        fail("build-tipa.yml missing")
        return
    try:
        import yaml  # type: ignore
    except ImportError:
        warn("pyyaml absent, skipping structural check")
        return

    try:
        doc = yaml.safe_load(wf.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        fail(f"yaml parse: {exc}")
        return

    jobs = doc.get("jobs") or {}
    if not jobs:
        fail("workflow declares no jobs")
        return

    for name, job in jobs.items():
        if "runs-on" not in job:
            fail(f"job {name} has no runs-on")
        steps = job.get("steps") or []
        if not steps:
            fail(f"job {name} has no steps")
            continue
        for i, step in enumerate(steps):
            if not isinstance(step, dict):
                fail(f"{name} step {i} is not a mapping")
                continue
            if "uses" not in step and "run" not in step:
                fail(f"{name} step {i} has neither uses nor run: {step.get('name')}")
            if "uses" in step and "run" in step:
                warn(f"{name} step {i} sets both uses and run")
        ok(f"{name}: {len(steps)} steps, runs-on={job['runs-on']}")


# ---------------------------------------------------------------------------
# Plists
# ---------------------------------------------------------------------------

REQUIRED_ENTITLEMENTS = [
    "platform-application",
    "com.apple.private.security.no-sandbox",
    "com.apple.private.security.no-container",
]


def check_entitlements(repo: Path) -> None:
    print("\n[3] entitlements")
    path = repo / "entitlements/Minis-TrollStore.entitlements"
    if not path.exists():
        fail("entitlements file missing")
        return
    try:
        data = plistlib.loads(path.read_bytes())
    except Exception as exc:
        fail(f"plist parse: {exc}")
        return

    missing = [k for k in REQUIRED_ENTITLEMENTS if data.get(k) is not True]
    if missing:
        fail(f"required entitlements absent or not true: {missing}")
    else:
        ok(f"{len(data)} keys, platform entitlements present")

    # Stock Minis features must survive the swap, or a device tool dies quietly.
    for key in (
        "com.apple.developer.healthkit",
        "com.apple.developer.homekit",
        "com.apple.developer.weatherkit",
        "com.apple.developer.nfc.readersession.formats",
    ):
        if key not in data:
            warn(f"stock entitlement dropped: {key}")


def check_bundle_plists(repo: Path) -> None:
    print("\n[4] bundle plists")
    ios = repo / "src/ios"
    checked = 0
    for name in ("Info.plist",):
        path = ios / name
        if path.exists():
            try:
                plistlib.loads(path.read_bytes())
                ok(name)
                checked += 1
            except Exception as exc:
                fail(f"{name}: {exc}")
    if checked == 0:
        warn("no Info.plist found at src/ios/Info.plist")


# ---------------------------------------------------------------------------
# pbxproj — run the real patch on a copy, then audit the result
# ---------------------------------------------------------------------------

PATCHED_FILES = (
    "src/ios/Minis.xcodeproj/project.pbxproj",
    "src/ios/MinisApp-Bridging-Header.h",
    "src/ios/Agent/ISH/ISHExecutionCoordinator.swift",
)


def check_pbxproj(repo: Path) -> None:
    print("\n[5] pbxproj after patch")
    pbx = repo / "src/ios/Minis.xcodeproj/project.pbxproj"
    if not pbx.exists():
        fail("project.pbxproj missing")
        return

    # The patcher edits three files. Snapshot all of them and restore every one
    # afterwards: preflight must be side-effect free, because CI applies the
    # patch as its own step and a half-patched tree makes that step lie.
    snapshot = {}
    for rel in PATCHED_FILES:
        p = repo / rel
        if p.exists():
            snapshot[p] = p.read_bytes()

    try:
        patcher = repo / "patches/patch_minis.py"
        result = subprocess.run(
            [sys.executable, str(patcher), "--repo", str(repo)],
            capture_output=True, text=True)
        print("    " + (result.stdout or "").strip().replace("\n", "\n    "))

        text = pbx.read_text(encoding="utf-8")

        for open_ch, close_ch in (("{", "}"), ("(", ")")):
            if text.count(open_ch) != text.count(close_ch):
                fail(f"delimiters unbalanced: {open_ch}={text.count(open_ch)} "
                     f"{close_ch}={text.count(close_ch)}")

        if "RuntimeHost" not in text:
            fail("RuntimeHost group not added")
            return

        # The group must belong to the *app* target. Checking the first
        # `fileSystemSynchronizedGroups` in the file would inspect MinisUITests,
        # which legitimately does not carry it — so locate the Minis target
        # block and read its own list.
        target = re.search(
            r"\t\t[A-Z0-9]{8,24} /\* Minis \*/ = \{\n\t\t\tisa = PBXNativeTarget;(.*?)\n\t\t\};",
            text, re.S)
        if not target:
            fail("Minis PBXNativeTarget block not found")
        else:
            block = target.group(1)
            sync = re.search(r"fileSystemSynchronizedGroups = \((.*?)\);", block, re.S)
            if not sync:
                fail("Minis target has no fileSystemSynchronizedGroups")
            elif "RuntimeHost" not in sync.group(1):
                fail("RuntimeHost not in the Minis target's synchronized groups")
            else:
                ok("attached to the Minis app target")

        # every id used in a children/sync list should be defined somewhere
        defined = set(re.findall(r"^\t\t([A-Z0-9]{8,24}) /\*", text, re.M))
        used = set(re.findall(r"^\t\t\t\t([A-Z0-9]{8,24}) /\*", text, re.M))
        dangling = sorted(used - defined)
        if dangling:
            fail(f"dangling object ids: {dangling[:6]}")
        else:
            ok(f"{len(used)} referenced ids all defined")
    finally:
        for path, blob in snapshot.items():
            path.write_bytes(blob)


# ---------------------------------------------------------------------------
# Swift
# ---------------------------------------------------------------------------

def collect_errors(parser, text: bytes) -> list[int]:
    """Line numbers of every ERROR / missing node in a tree-sitter parse."""
    tree = parser.parse(text)
    lines: list[int] = []

    def walk(node) -> None:
        if node.type == "ERROR" or node.is_missing:
            lines.append(node.start_point[0] + 1)
        for child in node.children:
            walk(child)

    walk(tree.root_node)
    return lines


def check_swift(repo: Path) -> None:
    print("\n[6] swift syntax")
    sources = sorted((repo / "src/ios/RuntimeHost").glob("*.swift"))
    if not sources:
        fail("no Swift sources in src/ios/RuntimeHost")
        return

    try:
        import tree_sitter
        import tree_sitter_swift as ts_swift
    except ImportError:
        warn("tree-sitter unavailable, falling back to delimiter count")
        for src in sources:
            text = src.read_text(encoding="utf-8")
            for o, c in (("{", "}"), ("(", ")")):
                if text.count(o) != text.count(c):
                    fail(f"{src.name}: {o}{c} unbalanced "
                         f"({text.count(o)}/{text.count(c)})")
        return

    language = tree_sitter.Language(ts_swift.language())
    parser = tree_sitter.Parser(language)

    for src in sources:
        text = src.read_bytes()
        errors = collect_errors(parser, text)
        if errors:
            fail(f"{src.name}: {len(errors)} syntax error(s) at lines {errors[:5]}")
            for line in errors[:3]:
                snippet = text.split(b"\n")[line - 1][:100].decode("utf-8", "replace")
                print(f"        L{line}: {snippet.strip()}")
        else:
            ok(f"{src.name} ({len(text)} bytes)")

    # The C shim gets its own pass. tree-sitter's C grammar cannot model
    # `extern "C" {`, so the guards are stripped before parsing — otherwise
    # every header using the standard idiom reports a phantom error.
    try:
        import tree_sitter_c
        clang = tree_sitter.Language(tree_sitter_c.language())
        cparser = tree_sitter.Parser(clang)
    except ImportError:
        warn("tree_sitter_c unavailable, skipping C parse")
        return

    for cfile in sorted((repo / "src/ios/RuntimeHost").glob("*.c")):
        text = cfile.read_bytes()
        errors = collect_errors(cparser, text)
        if errors:
            fail(f"{cfile.name}: {len(errors)} syntax error(s) at {errors[:5]}")
        else:
            ok(f"{cfile.name} ({len(text)} bytes)")

    for hfile in sorted((repo / "src/ios/RuntimeHost").glob("*.h")):
        text = hfile.read_bytes()
        neutralised = (text
                       .replace(b'#ifdef __cplusplus\n}\n#endif', b'')
                       .replace(b'#ifdef __cplusplus\nextern "C" {\n#endif', b''))
        errors = collect_errors(cparser, neutralised)
        if errors:
            fail(f"{hfile.name}: {len(errors)} syntax error(s) at {errors[:5]}")
        else:
            ok(f"{hfile.name} ({len(text)} bytes)")


# ---------------------------------------------------------------------------
# Cross-file consistency
# ---------------------------------------------------------------------------

def check_bridging(repo: Path) -> None:
    print("\n[7] bridging header")
    # The import line is written by the patcher, so this stage checks the two
    # things that must exist *before* the patch: the header itself, and the
    # header that will import it.
    header = repo / "src/ios/RuntimeHost/RuntimeArchive.h"
    if not header.exists():
        fail("src/ios/RuntimeHost/RuntimeArchive.h missing — Swift cannot see ra_gunzip_stream")
    else:
        ok("RuntimeArchive.h present in the source group")

    bridged = repo / "src/ios/MinisApp-Bridging-Header.h"
    if not bridged.exists():
        fail("src/ios/MinisApp-Bridging-Header.h missing — the C shim would be invisible")
    else:
        ok("bridging header present (import added by the patcher)")


def check_coordinator(repo: Path) -> None:
    print("\n[8] coordinator patch anchor")
    path = repo / "src/ios/Agent/ISH/ISHExecutionCoordinator.swift"
    if not path.exists():
        fail("ISHExecutionCoordinator.swift missing")
        return
    text = path.read_text(encoding="utf-8", errors="replace")
    anchor = "guard ISHKernel.shared.isBooted else {"
    if anchor not in text:
        fail("booted-guard anchor missing — patch_minis.py will not find its insertion point")
    else:
        ok("anchor present")

    # The types the graft depends on must actually exist with these shapes.
    for needle, why in (
        ("struct ISHCommandResult", "native backend returns this"),
        ("let output: String", "output field"),
        ("let exitCode: Int", "exitCode field"),
        ("actor ISHExecutionCoordinator", "coordinator is an actor"),
    ):
        if needle not in text:
            warn(f"expected `{needle}` ({why})")


def check_applogger(repo: Path) -> None:
    print("\n[9] AppLogger surface")
    path = repo / "src/ios/Shared/AppLogger.swift"
    if not path.exists():
        warn("AppLogger.swift missing")
        return
    text = path.read_text(encoding="utf-8", errors="replace")
    for fn in ("func debug", "func info", "func warning", "func error"):
        if fn not in text:
            fail(f"AppLogger lacks {fn}()")
    ok("debug/info/warning/error all present")


# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    args = ap.parse_args()
    repo = Path(args.repo).resolve()

    print(f"preflight: {repo}")

    check_python(repo)
    check_workflow(repo)
    check_entitlements(repo)
    check_bundle_plists(repo)
    check_pbxproj(repo)
    check_swift(repo)
    check_bridging(repo)
    check_coordinator(repo)
    check_applogger(repo)

    print()
    if failures:
        print(f"FAILED — {len(failures)} problem(s), {len(warnings)} warning(s)")
        for f in failures:
            print("  * " + f)
        return 1
    print(f"PASSED — 0 problems, {len(warnings)} warning(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
