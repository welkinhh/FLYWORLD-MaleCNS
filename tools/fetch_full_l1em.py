"""Fetch all public Winding 2023 L1EM SWC skeletons used by the local matrix."""

from __future__ import annotations

import json
import os
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "data" / "morphology_raw" / "larva_full"
INDEX = ROOT / "build" / "l1em_skeleton_index.json"
ENDPOINT = "https://l1em.catmaid.virtualflybrain.org/1/skeleton/{}/swc"


def fetch_one(skeleton_id: str) -> tuple[str, str]:
    OUT.mkdir(parents=True, exist_ok=True)
    target = OUT / f"{skeleton_id}.swc"
    if target.exists() and target.stat().st_size > 64:
        return skeleton_id, "cached"
    part = target.with_suffix(".swc.part")
    error: Exception | None = None
    for attempt in range(5):
        try:
            request = urllib.request.Request(ENDPOINT.format(skeleton_id), headers={"Connection": "close", "User-Agent": "FLYWORLD L1EM fetcher"})
            with urllib.request.urlopen(request, timeout=30) as response, part.open("wb") as file:
                file.write(response.read())
            if part.stat().st_size <= 64:
                raise IOError("empty SWC response")
            os.replace(part, target)
            return skeleton_id, "downloaded"
        except Exception as exc:
            error = exc
            if part.exists():
                part.unlink()
            time.sleep(min(2.0 * (attempt + 1), 10.0))
    return skeleton_id, f"failed: {error}"


def main() -> None:
    with np.load(ROOT / "brain_service" / "data" / "larva" / "l1em_connectome.npz", allow_pickle=False) as archive:
        ids = [str(value) for value in archive["ids"]]
    INDEX.parent.mkdir(parents=True, exist_ok=True)
    INDEX.write_text(json.dumps({"dataset_id": "Winding2023-L1EM", "endpoint": ENDPOINT, "ids": ids}, indent=2) + "\n", encoding="utf-8")
    downloaded = cached = failed = 0
    with ThreadPoolExecutor(max_workers=16) as pool:
        futures = [pool.submit(fetch_one, skeleton_id) for skeleton_id in ids]
        for future in as_completed(futures):
            skeleton_id, status = future.result()
            if status == "downloaded":
                downloaded += 1
            elif status == "cached":
                cached += 1
            else:
                failed += 1
                print(json.dumps({"id": skeleton_id, "status": status}), flush=True)
            done = downloaded + cached + failed
            if done % 25 == 0 or done == len(ids):
                print(json.dumps({"done": done, "total": len(ids), "downloaded": downloaded, "cached": cached, "failed": failed}), flush=True)
    if failed:
        raise SystemExit(f"{failed} L1EM skeletons failed")


if __name__ == "__main__":
    main()
