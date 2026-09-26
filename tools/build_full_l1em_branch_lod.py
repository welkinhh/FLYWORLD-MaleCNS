"""Convert all downloaded L1EM SWCs to the shared FWBR branch stream."""

from __future__ import annotations

import json
import struct
from pathlib import Path

from fetch_morphology import compact_nodes, parse_swc


ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "morphology_raw" / "larva_full"
OUT = ROOT / "assets" / "morphology" / "larva_full_branches.bin"
MAX_NODES = 48


def main() -> None:
    files = sorted(RAW.glob("*.swc"), key=lambda path: int(path.stem) if path.stem.isdigit() else path.stem)
    catalog = json.loads((ROOT / "assets" / "morphology" / "larva.json").read_text(encoding="utf-8"))
    transform = catalog.get("coordinate_transform", {})
    center = [float(value) for value in transform.get("center", [0.0, 0.0, 0.0])]
    span = max(float(transform.get("span", 1.0)), 1.0)
    display_span = float(transform.get("display_span", 3.8))
    scale = display_span / span
    total_nodes = 0
    failed = []
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("wb") as output:
        output.write(struct.pack("<4sII", b"FWBR", 1, len(files)))
        for path in files:
            try:
                nodes = compact_nodes(parse_swc(path.read_bytes()), max_nodes=MAX_NODES)
                index_by_id = {node["id"]: index for index, node in enumerate(nodes)}
                output.write(struct.pack("<qI", int(path.stem), len(nodes)))
                for node in nodes:
                    output.write(struct.pack(
                        "<4fi",
                        (float(node["x"]) - center[0]) * scale,
                        (float(node["y"]) - center[1]) * scale,
                        (float(node["z"]) - center[2]) * scale,
                        max(0.008, float(node["radius"]) * scale * 2.6),
                        index_by_id.get(node["parent"], -1),
                    ))
                total_nodes += len(nodes)
            except Exception as error:
                failed.append({"file": path.name, "error": str(error)})
    report = {
        "dataset_id": "Winding2023-L1EM",
        "raw_swc_count": len(files),
        "processed_swc_count": len(files) - len(failed),
        "display_nodes": total_nodes,
        "failed": failed,
        "complete": not failed and len(files) == 444,
        "asset": str(OUT),
        "coordinates": {"units": "nanometer", "center": center, "span": span, "display_span": display_span},
    }
    (ROOT / "build" / "larva_full_branch_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
