"""Build the small NumPy LIF slice used for L1EM larva observation.

The matrix is copied from Winding et al. Supplementary-Data-S1. The MVP keeps
the real neuron IDs and connection counts for the published ORN/PN/KC/APL/LN/
MBON/DAN populations, then normalises each postsynaptic row for a stable local
rate model. This is an explicit lightweight adapter, not a claim to reproduce
the paper's trained PyTorch model.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path

import numpy as np
import pandas as pd


ROOT = Path(__file__).resolve().parents[1]
IDS_JSON = ROOT / "brain_service" / "data" / "larva" / "neuron_ids.json"
OUT_DIR = ROOT / "brain_service" / "data" / "larva"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Path to the original Supplementary-Data-S1.zip")
    args = parser.parse_args()
    source_zip = args.source.resolve()
    if not source_zip.is_file():
        parser.error(f"Source archive not found: {source_zip}")
    groups_raw = json.loads(IDS_JSON.read_text(encoding="utf-8"))
    groups: dict[str, list[str]] = {}
    ordered_ids: list[str] = []
    for name, values in groups_raw.items():
        key = name.removesuffix("_ids")
        groups[key] = [str(value) for value in values]
        ordered_ids.extend(groups[key])
    ordered_ids = list(dict.fromkeys(ordered_ids))
    with zipfile.ZipFile(source_zip) as archive:
        with archive.open("Supplementary-Data-S1/all-all_connectivity_matrix.csv") as stream:
            matrix = pd.read_csv(stream, index_col=0)
    matrix.index = matrix.index.astype(str)
    matrix.columns = matrix.columns.astype(str)
    counts = matrix.loc[ordered_ids, ordered_ids].to_numpy(dtype=np.float32)
    row_sums = np.maximum(counts.sum(axis=1, keepdims=True), 1.0)
    weights = (counts / row_sums * 1.45).astype(np.float32)
    output_ids = np.asarray(ordered_ids, dtype="U32")
    group_indices = {
        name: np.asarray([ordered_ids.index(value) for value in values], dtype=np.int32)
        for name, values in groups.items()
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    npz_path = OUT_DIR / "l1em_connectome.npz"
    np.savez_compressed(
        npz_path,
        ids=output_ids,
        weights=weights,
        **group_indices,
    )
    metadata = {
        "dataset_id": "Winding2023-L1EM",
        "model_version": "L1EM connectome LIF-lite v1",
        "source_zip": source_zip.name,
        "source_sha256": sha256(source_zip),
        "neuron_count": len(ordered_ids),
        "matrix_shape": list(weights.shape),
        "normalization": "published all-all counts / postsynaptic row sum * 1.45",
        "dynamics": {
            "integrator": "v[t+1] = 0.86*v[t] + 0.60*W@spikes[t] + 0.10*input_drive",
            "threshold": 0.40,
            "dt_s": 0.02,
        },
        "groups": {name: len(values) for name, values in groups.items()},
        "asset": str(npz_path.relative_to(ROOT)),
    }
    (OUT_DIR / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({**metadata, "asset_sha256": sha256(npz_path)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
