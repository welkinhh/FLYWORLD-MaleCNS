"""Build a compact real-connectome edge LOD for the Godot brain viewer.

The source is the local MaleCNS v1.0 sparse matrix. We keep the strongest
outgoing entries per source neuron, preserving real source/target coordinates;
this is a render LOD, not a replacement for the complete synapse table.
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data" / "malecns"
OUT = ROOT / "assets" / "morphology" / "adult_connectome_edges.bin"
MAGIC = b"FWED"
PER_SOURCE = 4
MAX_EDGES = 700_000


def main() -> None:
    with np.load(DATA / "brain.npz", allow_pickle=False) as archive:
        positions = archive["positions"].astype(np.float32, copy=False)
        ids = archive["ids"].astype(np.int64, copy=False)
    with np.load(DATA / "weights.npz", allow_pickle=False) as archive:
        indptr = archive["indptr"].astype(np.int64, copy=False)
        indices = archive["indices"].astype(np.int64, copy=False)
        data = archive["data"].astype(np.float32, copy=False)

    finite = np.isfinite(positions).all(axis=1)
    catalog = json.loads((ROOT / "assets" / "morphology" / "adult.json").read_text(encoding="utf-8"))
    transform = catalog.get("coordinate_transform", {})
    raw_center = transform.get("center", [])
    center = np.asarray(raw_center if len(raw_center) == 3 else np.nanmean(positions[finite], axis=0), dtype=np.float32)
    span = float(transform.get("span", np.nanmax(positions[finite], axis=0).max() - np.nanmin(positions[finite], axis=0).min()))
    display_span = float(transform.get("display_span", 3.8))
    scale = display_span / max(span, 1.0)

    edges: list[tuple[np.ndarray, np.ndarray, float]] = []
    for source in range(min(len(ids), len(indptr) - 1)):
        if not finite[source]:
            continue
        start, end = int(indptr[source]), int(indptr[source + 1])
        if end <= start:
            continue
        row_indices = indices[start:end]
        row_data = data[start:end]
        valid = (row_indices >= 0) & (row_indices < len(ids)) & finite[row_indices]
        if not valid.any():
            continue
        row_indices = row_indices[valid]
        row_data = row_data[valid]
        keep_count = min(PER_SOURCE, len(row_indices))
        if len(row_indices) > keep_count:
            selected = np.argpartition(np.abs(row_data), -keep_count)[-keep_count:]
        else:
            selected = np.arange(len(row_indices))
        source_point = (positions[source] - center) * scale
        for selected_index in selected:
            target = int(row_indices[selected_index])
            target_point = (positions[target] - center) * scale
            if np.isfinite(target_point).all():
                edges.append((source_point, target_point, float(row_data[selected_index])))

    if len(edges) > MAX_EDGES:
        # Deterministic strength-biased LOD so every run produces the same
        # render asset and keeps strong long-range connections visible.
        strengths = np.asarray([abs(edge[2]) for edge in edges], dtype=np.float32)
        chosen = np.argpartition(strengths, -MAX_EDGES)[-MAX_EDGES:]
        edges = [edges[int(index)] for index in chosen]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("wb") as file:
        file.write(struct.pack("<4sI", MAGIC, len(edges)))
        for source_point, target_point, weight in edges:
            file.write(struct.pack("<7f", *source_point.tolist(), *target_point.tolist(), weight))
    report = {
        "dataset_id": "MaleCNS-v1.0",
        "source_neurons": int(len(ids)),
        "source_connections": int(len(data)),
        "render_edges": len(edges),
        "per_source_cap": PER_SOURCE,
        "max_edges": MAX_EDGES,
        "coordinate_transform": {"center": center.tolist(), "span": span, "display_span": display_span},
        "lod": "strongest absolute-weight real matrix entries; not a complete synapse render",
        "output": str(OUT),
    }
    (ROOT / "build" / "connectome_edges_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
