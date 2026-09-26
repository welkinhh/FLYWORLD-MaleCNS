"""Index and optionally fetch the complete public MaleCNS SWC catalog.

This is resumable and keeps a provenance index. It does not silently replace
the checked-in ten-neuron catalog. Use --index-only for a metadata pass and
--download to fetch every neuron listed in the local brain.npz.
"""

from __future__ import annotations

import argparse
import json
import os
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

import numpy as np


ROOT = Path(__file__).resolve().parents[1]
BUCKET = "flyem-male-cns"
PREFIX = "v1.0/segmentation/skeletons-malecns/skeletons-swc/"
INDEX_PATH = ROOT / "build" / "malecns_skeleton_index.json"
OUT_ROOT = ROOT / "data" / "morphology_raw" / "adult_full"


def get_json(url: str, retries: int = 6) -> dict[str, Any]:
    error: Exception | None = None
    for attempt in range(retries):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "FLYWORLD full morphology fetcher", "Connection": "close"})
            with urllib.request.urlopen(request, timeout=90) as response:
                return json.loads(response.read().decode("utf-8"))
        except Exception as exc:  # network endpoints occasionally close long pages
            error = exc
            time.sleep(min(2.0 * (attempt + 1), 12.0))
    raise RuntimeError(f"failed GET after {retries} attempts: {url}: {error}")


def expected_ids() -> set[str]:
    with np.load(ROOT / "data" / "malecns" / "brain.npz", allow_pickle=False) as archive:
        return {str(int(value)) for value in archive["ids"]}


def build_index() -> list[dict[str, Any]]:
    wanted = expected_ids()
    page_token = ""
    objects: list[dict[str, Any]] = []
    while True:
        # Smaller pages avoid truncated HTTP responses from the public bucket
        # while remaining resumable through the page token.
        params: dict[str, str | int] = {"prefix": PREFIX, "maxResults": 200}
        if page_token:
            params["pageToken"] = page_token
        url = f"https://storage.googleapis.com/storage/v1/b/{BUCKET}/o?{urllib.parse.urlencode(params)}"
        data = get_json(url)
        for item in data.get("items", []):
            name = str(item.get("name", ""))
            neuron_id = name.removeprefix(PREFIX).removesuffix(".swc")
            if neuron_id in wanted:
                objects.append({
                    "neuron_id": neuron_id,
                    "name": name,
                    "media_link": str(item.get("mediaLink", "")),
                    "size": int(item.get("size", 0)),
                    "md5": str(item.get("md5Hash", "")),
                    "updated": str(item.get("updated", "")),
                })
        page_token = str(data.get("nextPageToken", ""))
        if not page_token:
            break
    objects.sort(key=lambda item: int(item["neuron_id"]) if item["neuron_id"].isdigit() else item["neuron_id"])
    INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
    INDEX_PATH.write_text(json.dumps({
        "dataset_id": "MaleCNS-v1.0",
        "prefix": PREFIX,
        "expected_neurons": len(wanted),
        "indexed_neurons": len(objects),
        "total_bytes": sum(item["size"] for item in objects),
        "objects": objects,
    }, indent=2) + "\n", encoding="utf-8")
    return objects


def download_one(item: dict[str, Any]) -> tuple[str, int, str]:
    OUT_ROOT.mkdir(parents=True, exist_ok=True)
    neuron_id = str(item["neuron_id"])
    target = OUT_ROOT / f"{neuron_id}.swc"
    if target.exists() and target.stat().st_size == int(item["size"]):
        return neuron_id, target.stat().st_size, "cached"
    part = target.with_suffix(".swc.part")
    error: Exception | None = None
    for attempt in range(6):
        try:
            request = urllib.request.Request(str(item["media_link"]), headers={"User-Agent": "FLYWORLD full morphology fetcher"})
            with urllib.request.urlopen(request, timeout=30) as response, part.open("wb") as file:
                while True:
                    chunk = response.read(1024 * 1024)
                    if not chunk:
                        break
                    file.write(chunk)
            if part.stat().st_size != int(item["size"]):
                raise IOError(f"size mismatch: {part.stat().st_size} != {item['size']}")
            os.replace(part, target)
            return neuron_id, target.stat().st_size, "downloaded"
        except Exception as exc:
            error = exc
            if part.exists():
                part.unlink()
            time.sleep(min(2.0 * (attempt + 1), 15.0))
    return neuron_id, 0, f"failed: {error}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index-only", action="store_true")
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--refresh-index", action="store_true")
    parser.add_argument("--workers", type=int, default=24)
    parser.add_argument("--batch-size", type=int, default=500)
    args = parser.parse_args()
    if INDEX_PATH.exists() and not args.refresh_index:
        indexed = json.loads(INDEX_PATH.read_text(encoding="utf-8"))
        objects = indexed.get("objects", [])
        if len(objects) != len(expected_ids()):
            objects = build_index()
    else:
        objects = build_index()
    total = sum(item["size"] for item in objects)
    print(json.dumps({"indexed": len(objects), "expected": len(expected_ids()), "bytes": total, "gb": total / 1e9}, ensure_ascii=False), flush=True)
    if not args.download or args.index_only:
        return
    completed = failed = cached = 0
    with ThreadPoolExecutor(max_workers=max(1, min(args.workers, 64))) as pool:
        for batch_start in range(0, len(objects), max(1, args.batch_size)):
            batch = objects[batch_start:batch_start + max(1, args.batch_size)]
            futures = [pool.submit(download_one, item) for item in batch]
            for future in as_completed(futures):
                neuron_id, size, status = future.result()
                if status == "downloaded":
                    completed += 1
                elif status == "cached":
                    cached += 1
                else:
                    failed += 1
                    print(json.dumps({"neuron_id": neuron_id, "status": status}), flush=True)
                done = completed + cached + failed
                if done % 500 == 0 or done == len(objects):
                    print(json.dumps({"done": done, "total": len(objects), "downloaded": completed, "cached": cached, "failed": failed}), flush=True)
    if failed:
        raise SystemExit(f"{failed} skeleton downloads failed; rerun to resume")


if __name__ == "__main__":
    main()
