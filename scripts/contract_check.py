#!/usr/bin/env python3
"""
contract_check.py — validate the Swift Decodable layer against the real
runtime documents, without an iOS toolchain.

Why this exists: JSON decoding fails *silently by design*. A CodingKey typo, or
a non-optional property whose key is absent from one document, makes a field
decode as nil (or the whole document fail to decode) and the install quietly
does the wrong thing — signs no binaries, resolves no PATH, reports success.

Two checks per modelled struct:

  keys   — every JSON key named in CodingKeys must exist in at least one real
           document. A misspelling shows up here instead of as a nil at runtime.
  fields — every NON-OPTIONAL Swift property must have its key present in every
           document of that shape. This is the one that matters: one missing key
           makes the entire document fail to decode, and the failure surfaces
           nowhere.

Offline and deterministic: reads verify/contract-snapshot.json, which holds key
names harvested from the published documents (see the comment in that file).

    python3 scripts/contract_check.py --repo .
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# struct name -> which snapshot section its keys must come from
SECTIONS = {
    "RuntimeManifest": "manifest_root",
    "RuntimeSpec": "manifest_runtime",
    "InstallInstructions": "install",
    "InstallProbe": "probe",
    "RuntimeBundle": "bundle",
    "ShebangRewrite": "shebang",
}

failures: list[str] = []
warnings: list[str] = []


def find_struct_bodies(text: str) -> dict[str, tuple[str, int]]:
    """struct name -> (body text, line number of the declaration)."""
    bodies: dict[str, tuple[str, int]] = {}
    for m in re.finditer(r"\bstruct\s+(\w+)\s*:\s*[^{]*\bDecodable\b[^{]*\{", text):
        name = m.group(1)
        start = m.end() - 1
        depth = 0
        i = start
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        line = text[: m.start()].count("\n") + 1
        bodies[name] = (text[start + 1 : i], line)
    return bodies


def parse_coding_keys(body: str) -> dict[str, str] | None:
    """swiftName -> jsonKey, from an explicit CodingKeys enum, or None."""
    m = re.search(r"enum\s+CodingKeys\s*:[^{]*\{", body)
    if not m:
        return None
    start = m.end() - 1
    depth = 0
    i = start
    while i < len(body):
        if body[i] == "{":
            depth += 1
        elif body[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    block = body[start + 1 : i]

    mapping: dict[str, str] = {}
    for line in block.split("\n"):
        line = line.strip()
        if not line.startswith("case "):
            continue
        line = line[5:].strip()
        if line.endswith(","):
            line = line[:-1]
        # `a = "b"` or a bare list `a, b, c`
        if "=" in line:
            for part in line.split(","):
                part = part.strip()
                if not part:
                    continue
                name, _, key = part.partition("=")
                key = key.strip().strip('"')
                mapping[name.strip()] = key
        else:
            for part in line.split(","):
                part = part.strip()
                if part:
                    mapping[part] = part
    return mapping


def parse_properties(body: str) -> list[tuple[str, str, int]]:
    """(name, type, offset) for every `let` in the struct body."""
    props = []
    for m in re.finditer(r"\n\s*let\s+(\w+)\s*:\s*([^\n=]+)", body):
        props.append((m.group(1), m.group(2).strip(), m.start()))
    return props


def is_optional(type_text: str) -> bool:
    return type_text.rstrip().endswith("?")


def parse_custom_init(body: str) -> str | None:
    """Body of `init(from decoder: Decoder)`, or None for synthesised decoding."""
    m = re.search(r"init\s*\(\s*from\s+\w*\s*:\s*Decoder\s*\)", body)
    if not m:
        return None
    brace = body.find("{", m.end())
    if brace < 0:
        return None
    depth = 0
    i = brace
    while i < len(body):
        if body[i] == "{":
            depth += 1
        elif body[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return body[brace + 1 : i]


def strict_decoded_keys(init_body: str, mapping: dict[str, str]) -> set[str]:
    """
    JSON keys the init reads with a *strict* decode() rather than decodeIfPresent().

    The regex distinguishes them because `decodeIfPresent` has no `(` immediately
    after `decode`. Case names are resolved through the CodingKeys mapping so the
    comparison is against JSON keys, not Swift identifiers.
    """
    out: set[str] = set()
    for m in re.finditer(r"\.decode\s*\(([^)]*?)forKey\s*:\s*\.(\w+)", init_body):
        case = m.group(2)
        out.add(mapping.get(case, case))
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    args = ap.parse_args()
    repo = Path(args.repo).resolve()

    snap_path = repo / "verify" / "contract-snapshot.json"
    if not snap_path.exists():
        print("  skip  contract-snapshot.json absent")
        return 0
    snap = json.loads(snap_path.read_text(encoding="utf-8"))

    union = set()
    for section, value in snap.items():
        if isinstance(value, list) and not section.endswith("_intersection") \
                and section not in ("handlers_seen", "bundle_documents"):
            union |= set(value)

    sources = sorted((repo / "src/ios/RuntimeHost").glob("*.swift"))
    seen_structs = set()

    for src in sources:
        text = src.read_text(encoding="utf-8", errors="replace")
        for name, (body, line) in find_struct_bodies(text).items():
            seen_structs.add(name)
            section = SECTIONS.get(name)
            allowed = set(snap.get(section, [])) if section else union
            # A non-optional property needs the key in EVERY document of the
            # shape, not merely in one of them.
            required_keys = set(snap.get(f"{section}_intersection", [])) if section else set()

            mapping = parse_coding_keys(body)
            if mapping is None:
                # No explicit CodingKeys: property names are the JSON keys.
                mapping = {p: p for p, _t, _o in parse_properties(body)}

            # keys: every declared JSON key must exist somewhere real
            for swift_name, json_key in mapping.items():
                if json_key not in allowed:
                    failures.append(
                        f"{src.name}: {name}.{swift_name} maps to \"{json_key}\", "
                        f"which appears in no real document"
                        + (f" ({section})" if section else ""))

            # fields: non-optional properties must survive decoding everywhere.
            #
            # When the struct writes its own `init(from:)`, the init decides what
            # a missing key means, so the rule changes: a non-optional property
            # whose key is missing from some document is fine *if* the init reads
            # it with decodeIfPresent. A strict decode() there would still throw,
            # and that is what gets flagged.
            if section:
                custom_init = parse_custom_init(body)
                strict_keys = (strict_decoded_keys(custom_init, mapping)
                               if custom_init is not None else set())
                for prop, type_text, _off in parse_properties(body):
                    if is_optional(type_text):
                        continue
                    json_key = mapping.get(prop, prop)
                    if json_key not in allowed:
                        continue  # already reported above
                    if custom_init is not None:
                        if json_key in required_keys:
                            continue
                        if json_key in strict_keys:
                            failures.append(
                                f"{src.name}: {name}.{prop} is non-optional and its "
                                f"init uses a strict decode for \"{json_key}\", which "
                                f"is missing from at least one real {section} document")
                        else:
                            warnings.append(
                                f"{src.name}: {name}.{prop} defaults when "
                                f"\"{json_key}\" is absent (custom init)")
                    elif json_key not in required_keys:
                        failures.append(
                            f"{src.name}: {name}.{prop} is non-optional but "
                            f"\"{json_key}\" is missing from at least one real "
                            f"{section} document — decoding will throw for that one")

            print(f"  ok    {name:22} {len(mapping):3} key(s)"
                  + (f"  section={section}" if section else "  (union)"))

    for name in SECTIONS:
        if name not in seen_structs:
            failures.append(f"struct {name} not found — renamed or removed?")

    print()
    if failures:
        print(f"FAILED — {len(failures)} contract violation(s)")
        for f in failures:
            print("  * " + f)
        return 1
    print("PASSED — every modelled key exists and every required field is present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
