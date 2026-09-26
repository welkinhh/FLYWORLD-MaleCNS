"""Fetch and compact a small, provenance-tracked set of real fly skeletons."""

from __future__ import annotations

import hashlib
import json
import math
import ssl
import urllib.request
from collections import defaultdict
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(__file__).resolve().parent.parent
RAW_ROOT = PROJECT_ROOT / "data" / "morphology_raw"
ASSET_ROOT = PROJECT_ROOT / "assets" / "morphology"
CONTEXT = ssl.create_default_context()
OPENER = urllib.request.build_opener(urllib.request.HTTPSHandler(context=CONTEXT))

ADULT_NEURONS = {
    "10001": "DNp01_L",
    "10010": "DNp01_R",
    "10045": "DNg100_L",
    "10056": "DNg100_R",
    "10360": "DNa02_L",
    "523769": "DNa02_R",
    "10763": "MDN_L",
    "11288": "MDN_R",
    "25582": "BM_Taste_01",
    "35051": "BM_Taste_02",
}

LARVA_SKELETONS = {
    "29": "L1EM_neuron_29",
    "11995": "L1EM_neuron_11995",
    "23233": "L1EM_neuron_23233",
}


def fetch_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "FLYWORLD morphology asset fetcher"})
    with OPENER.open(request, timeout=90) as response:
        return response.read()


def parse_swc(raw: bytes) -> list[dict[str, Any]]:
    nodes: list[dict[str, Any]] = []
    for line in raw.decode("utf-8", "replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 7:
            continue
        try:
            node_id = int(fields[0])
            node_type = int(fields[1])
            x, y, z, radius = (float(fields[i]) for i in range(2, 6))
            parent = int(fields[6])
        except (TypeError, ValueError):
            continue
        if not all(math.isfinite(value) for value in (x, y, z, radius)):
            continue
        nodes.append({"id": node_id, "type": node_type, "x": x, "y": y, "z": z, "radius": max(radius, 0.0), "parent": parent})
    if not nodes:
        raise ValueError("SWC contained no finite nodes")
    ids = {node["id"] for node in nodes}
    if any(node["parent"] != -1 and node["parent"] not in ids for node in nodes):
        raise ValueError("SWC contains a parent reference that is not present")
    if any(node["parent"] == node["id"] for node in nodes):
        raise ValueError("SWC contains a self-parent")
    return nodes


def compact_nodes(nodes: list[dict[str, Any]], max_nodes: int = 420) -> list[dict[str, Any]]:
    if len(nodes) <= max_nodes:
        return nodes
    by_id = {node["id"]: node for node in nodes}
    children: dict[int, list[int]] = defaultdict(list)
    roots: list[int] = []
    for node in nodes:
        if node["parent"] == -1:
            roots.append(node["id"])
        else:
            children[node["parent"]].append(node["id"])
    depth: dict[int, int] = {}
    stack = [(root, 0) for root in roots]
    while stack:
        current, current_depth = stack.pop()
        depth[current] = current_depth
        stack.extend((child, current_depth + 1) for child in children[current])
    structural = [
        node["id"]
        for node in nodes
        if node["id"] in roots or len(children[node["id"]]) != 1
    ]
    stride = max(2, int(math.ceil(len(nodes) / max_nodes)))
    sampled = [node["id"] for node in nodes if depth.get(node["id"], 0) % stride == 0]
    ordered_candidates = []
    seen = set()
    for node_id in roots + structural + sampled:
        if node_id not in seen:
            ordered_candidates.append(node_id)
            seen.add(node_id)
    if len(ordered_candidates) > max_nodes:
        pick_stride = len(ordered_candidates) / max_nodes
        keep = {ordered_candidates[min(int(i * pick_stride), len(ordered_candidates) - 1)] for i in range(max_nodes)}
        keep.update(roots)
    else:
        keep = set(ordered_candidates)
    # Link each retained node to its nearest retained ancestor. This preserves
    # the branch direction without re-adding every intermediate SWC node.
    compacted = []
    for node in nodes:
        node_id = node["id"]
        if node_id not in keep:
            continue
        parent = node["parent"]
        while parent != -1 and parent not in keep:
            parent = by_id[parent]["parent"]
        compacted.append({**node, "parent": parent})
    return compacted[:max_nodes]


def normalize_group(neurons: list[dict[str, Any]], units: str, stage: str, dataset: str) -> dict[str, Any]:
    all_points = [(node["x"], node["y"], node["z"]) for neuron in neurons for node in neuron["nodes"]]
    minimum = [min(point[i] for point in all_points) for i in range(3)]
    maximum = [max(point[i] for point in all_points) for i in range(3)]
    center = [(minimum[i] + maximum[i]) * 0.5 for i in range(3)]
    span = max(maximum[i] - minimum[i] for i in range(3)) or 1.0
    display_span = 3.8
    for neuron in neurons:
        for node in neuron["nodes"]:
            node["p"] = [round((node["x"] - center[0]) / span * display_span, 6),
                          round((node["y"] - center[1]) / span * display_span, 6),
                          round((node["z"] - center[2]) / span * display_span, 6)]
            node["r"] = round(max(0.008, node["radius"] / span * display_span * 2.6), 6)
            node["id"] = str(node["id"])
            node["parent"] = str(node["parent"]) if node["parent"] != -1 else "-1"
            for key in ("x", "y", "z", "radius", "type"):
                node.pop(key, None)
    return {
        "dataset": dataset,
        "stage": stage,
        "units": units,
        "coordinate_transform": {"center": center, "span": span, "display_span": display_span},
        "visual_radius_floor": 0.008,
        "neurons": neurons,
    }


def download_group(entries: dict[str, str], stage: str) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    raw_group = RAW_ROOT / stage
    raw_group.mkdir(parents=True, exist_ok=True)
    compact: list[dict[str, Any]] = []
    manifest: list[dict[str, Any]] = []
    for source_id, label in entries.items():
        if stage == "adult_malecns":
            url = f"https://storage.googleapis.com/flyem-male-cns/v1.0/segmentation/skeletons-malecns/skeletons-swc/{source_id}.swc"
            units = "8nm"
            dataset = "MaleCNS v1.0"
        else:
            url = f"https://l1em.catmaid.virtualflybrain.org/1/skeleton/{source_id}/swc"
            units = "nanometer"
            dataset = "Winding 2023 L1EM CATMAID"
        path = raw_group / f"{source_id}.swc"
        if path.exists():
            raw = path.read_bytes()
        else:
            print(f"downloading {url}", flush=True)
            raw = fetch_bytes(url)
            path.write_bytes(raw)
        nodes = parse_swc(raw)
        compact_nodes_list = compact_nodes(nodes)
        compact.append({"neuron_id": str(source_id), "label": label, "nodes": compact_nodes_list})
        manifest.append({
            "neuron_id": str(source_id),
            "label": label,
            "stage": stage,
            "dataset": dataset,
            "source_url": url,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "raw_node_count": len(nodes),
            "display_node_count": len(compact_nodes_list),
            "downsampling": "retain roots, branch/terminal nodes and depth stride; restore parent chains",
            "coordinate_units": units,
        })
        print(f"{stage} {source_id}: {len(nodes)} -> {len(compact_nodes_list)} nodes", flush=True)
    return compact, manifest


def main() -> None:
    ASSET_ROOT.mkdir(parents=True, exist_ok=True)
    adult, adult_manifest = download_group(ADULT_NEURONS, "adult_malecns")
    larva, larva_manifest = download_group(LARVA_SKELETONS, "larva_l1em")
    adult_catalog = normalize_group(adult, "8nm", "adult", "MaleCNS v1.0")
    larva_catalog = normalize_group(larva, "nanometer", "larva_l1", "Winding 2023 L1EM CATMAID")
    (ASSET_ROOT / "adult.json").write_text(json.dumps(adult_catalog, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    (ASSET_ROOT / "larva.json").write_text(json.dumps(larva_catalog, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    manifest = {
        "asset_version": 1,
        "adult": adult_manifest,
        "larva": larva_manifest,
        "processing": "SWC parsed, topology-preserving downsampling, global display normalization, radius floor",
    }
    (ASSET_ROOT / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {ASSET_ROOT}", flush=True)


if __name__ == "__main__":
    main()
