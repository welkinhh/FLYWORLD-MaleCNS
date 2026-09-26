"""Convert downloaded MaleCNS SWCs into a compact, provenance-preserving branch stream.

The stream is intentionally separate from the checked-in ten-neuron catalog.
It contains real parent links and normalized 8 nm coordinates. Runtime loading
can choose chunks/LOD without reparsing 166k text files.
"""

from __future__ import annotations

import json
import struct
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

from fetch_morphology import compact_nodes, parse_swc


ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "morphology_raw" / "adult_full"
OUT = ROOT / "assets" / "morphology" / "adult_full_branches.bin"
REPORT = ROOT / "build" / "adult_full_branch_report.json"
MAX_NODES = 48
MAGIC = b"FWBR"


def process_one(path: Path, center: list[float], scale: float) -> tuple[str, list[dict], str | None]:
    try:
        raw_nodes = parse_swc(path.read_bytes())
        nodes = compact_nodes(raw_nodes, max_nodes=MAX_NODES)
        index_by_id = {node["id"]: node_index for node_index, node in enumerate(nodes)}
        encoded: list[dict] = []
        for node in nodes:
            encoded.append({
                "x": (float(node["x"]) - center[0]) * scale,
                "y": (float(node["y"]) - center[1]) * scale,
                "z": (float(node["z"]) - center[2]) * scale,
                "r": max(0.008, float(node["radius"]) * scale * 2.6),
                "parent": index_by_id.get(node["parent"], -1),
            })
        return path.stem, encoded, None
    except Exception as error:
        return path.stem, [], str(error)


def process_one_task(args: tuple[str, list[float], float]) -> tuple[str, list[dict], str | None]:
    path, center, scale = args
    return process_one(Path(path), center, scale)


def main() -> None:
    files = sorted(RAW.glob("*.swc"), key=lambda path: int(path.stem) if path.stem.isdigit() else path.stem)
    if not files:
        raise SystemExit(f"no SWC files under {RAW}")
    catalog = json.loads((ROOT / "assets" / "morphology" / "adult.json").read_text(encoding="utf-8"))
    transform = catalog.get("coordinate_transform", {})
    center = [float(value) for value in transform.get("center", [0.0, 0.0, 0.0])]
    span = max(float(transform.get("span", 1.0)), 1.0)
    display_span = float(transform.get("display_span", 3.8))
    scale = display_span / span
    OUT.parent.mkdir(parents=True, exist_ok=True)
    node_total = 0
    failed = []
    with OUT.open("wb") as output:
        output.write(struct.pack("<4sII", MAGIC, 1, len(files)))
        with ProcessPoolExecutor(max_workers=8) as pool:
            for batch_start in range(0, len(files), 1000):
                batch = files[batch_start:batch_start + 1000]
                tasks = [(str(path), center, scale) for path in batch]
                results = list(pool.map(process_one_task, tasks, chunksize=8))
                batch_bytes = bytearray()
                for path, (neuron_id, nodes, error) in zip(batch, results):
                    if error is not None:
                        failed.append({"file": path.name, "error": error})
                        continue
                    batch_bytes.extend(struct.pack("<qI", int(neuron_id), len(nodes)))
                    for node in nodes:
                        batch_bytes.extend(struct.pack("<4fi", node["x"], node["y"], node["z"], node["r"], node["parent"]))
                    node_total += len(nodes)
                output.write(batch_bytes)
                processed = min(batch_start + len(batch), len(files))
                print(json.dumps({"processed": processed, "total": len(files), "nodes": node_total, "failed": len(failed)}), flush=True)
    report = {
        "dataset_id": "MaleCNS-v1.0",
        "raw_swc_count": len(files),
        "processed_swc_count": len(files) - len(failed),
        "display_nodes": node_total,
        "max_nodes_per_neuron": MAX_NODES,
        "failed": failed[:100],
        "complete": not failed,
        "asset": str(OUT),
        "coordinates": {"units": "8nm", "center": center, "span": span, "display_span": display_span},
        "processing": "topology-preserving SWC compaction with parent-index stream",
    }
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
