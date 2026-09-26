"""Verify committed asset hashes and report the actual bundled coverage."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    lock = json.loads((ROOT / "SOURCES.lock.json").read_text(encoding="utf-8"))
    manifest = json.loads((ROOT / "assets/morphology/manifest.json").read_text(encoding="utf-8"))
    assets = []
    failures = []
    for source in lock["sources"]:
        for path_key, hash_key in [("asset", "asset_sha256"),
                                   ("connectome_asset", "connectome_asset_sha256")]:
            if path_key not in source or hash_key not in source:
                continue
            path = ROOT / source[path_key]
            actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
            valid = actual == source[hash_key]
            assets.append({"path": source[path_key], "sha256": actual, "valid": valid})
            if not valid:
                failures.append(source[path_key])
    adult = json.loads((ROOT / "assets/morphology/adult.json").read_text(encoding="utf-8"))
    larva = json.loads((ROOT / "assets/morphology/larva.json").read_text(encoding="utf-8"))
    report = {
        "assets": assets,
        "adult": {
            "expected_neurons": 166700,
            "detailed_catalog_neurons": len(adult["neurons"]),
            "runtime_skeletons": manifest["adult_runtime_branch_lod"]["runtime_skeletons"],
            "complete": False,
            "note": "Bundled adult morphology is a subset; full SWC downloads are optional.",
        },
        "larva": {
            "detailed_catalog_neurons": len(larva["neurons"]),
            "note": "444-neuron L1EM subset; not the complete larval connectome.",
        },
        "failures": failures,
    }
    output = ROOT / "build/morphology_coverage_report.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
