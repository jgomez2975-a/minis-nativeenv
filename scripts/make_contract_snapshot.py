#!/usr/bin/env python3
"""
make_contract_snapshot.py — harvest key names from the live runtime documents.

Writes the file scripts/contract_check.py validates the Swift Decodable layer
against. Two facts per document shape:

  <shape>               union of keys across all instances
  <shape>_intersection  keys present in EVERY instance

The union is what a CodingKey may legally name. The intersection is what a
NON-OPTIONAL Swift property needs, because Swift treats an Optional as "may be
absent" and never as "may be a different shape" — a key present with the wrong
type, or absent from one instance, throws and takes the whole document down.

Only key names are stored. No values, versions or URLs reach the repository.

    python3 scripts/make_contract_snapshot.py \
        verify/contract-snapshot.json \
        /tmp/docs/manifest.json \
        /tmp/docs
"""

from __future__ import annotations

import json
import pathlib
import sys


def intersect(sets):
    sets = [s for s in sets if s is not None]
    if not sets:
        return []
    acc = set(sets[0])
    for s in sets[1:]:
        acc &= set(s)
    return sorted(acc)


def main() -> int:
    if len(sys.argv) < 4:
        print("usage: make_contract_snapshot.py <out.json> <manifest.json> <docs-dir>")
        return 2

    out_path = pathlib.Path(sys.argv[1])
    manifest_path = pathlib.Path(sys.argv[2])
    docs_dir = pathlib.Path(sys.argv[3])

    manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    specs = list(manifest["runtimes"].values())

    runtime_sets = [set(s.keys()) for s in specs]
    ui_sets = [set((s.get("ui") or {}).keys()) for s in specs
               if isinstance(s.get("ui"), dict)]
    install_sets = [set(s["install"].keys()) for s in specs
                    if isinstance(s.get("install"), dict)]
    probe_sets = [set(s["install"]["probe"].keys()) for s in specs
                  if isinstance(s.get("install"), dict)
                  and isinstance(s["install"].get("probe"), dict)]

    bundle_sets = []
    bundle_install_sets = []
    shebang_sets = []
    for path in sorted(docs_dir.glob("*.json")):
        if path.name == manifest_path.name:
            continue
        try:
            doc = json.loads(path.read_text(encoding="utf-8-sig"))
        except Exception:
            continue
        if "runtimes" in doc:
            continue  # the manifest itself
        bundle_sets.append(set(doc.keys()))
        if isinstance(doc.get("install"), dict):
            bundle_install_sets.append(set(doc["install"].keys()))
        for sb in doc.get("portable_shebangs") or []:
            shebang_sets.append(set(sb.keys()))

    all_install = install_sets + bundle_install_sets

    snapshot = {
        "_comment": "Key names only, harvested from the published runtime documents. "
                    "Union = what a CodingKey may name; intersection = what a "
                    "non-optional property requires. Regenerate with "
                    "scripts/make_contract_snapshot.py.",
        "manifest_root": sorted(manifest.keys()),
        "manifest_root_intersection": sorted(manifest.keys()),
        "manifest_runtime": sorted(set().union(*runtime_sets)),
        "manifest_runtime_intersection": intersect(runtime_sets),
        "ui": sorted(set().union(*ui_sets)) if ui_sets else [],
        "ui_intersection": intersect(ui_sets),
        "install": sorted(set().union(*all_install)) if all_install else [],
        "install_intersection": intersect(all_install),
        "probe": sorted(set().union(*probe_sets)) if probe_sets else [],
        "probe_intersection": intersect(probe_sets),
        "bundle": sorted(set().union(*bundle_sets)) if bundle_sets else [],
        "bundle_intersection": intersect(bundle_sets),
        "shebang": sorted(set().union(*shebang_sets)) if shebang_sets else [],
        "shebang_intersection": intersect(shebang_sets),
        "handlers_seen": sorted({s.get("handler") for s in specs if s.get("handler")}),
        "bundle_documents": sorted(p.stem for p in docs_dir.glob("*.json")
                                   if p.name != manifest_path.name),
        "counts": {
            "manifest_runtimes": len(specs),
            "install_documents": len(all_install),
            "bundle_documents": len(bundle_sets),
        },
    }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

    print(f"wrote {out_path} ({out_path.stat().st_size} bytes)")
    for key, value in snapshot.items():
        if isinstance(value, list):
            print(f"  {key:32} {len(value):3}")
    print(f"  install documents: {len(all_install)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
