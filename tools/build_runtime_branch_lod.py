"""Create a compact runtime branch stream from a complete FWBR asset.

The complete stream remains the provenance/archive asset.  The runtime viewer
uses this deterministic every-Nth-neuron stream so startup and stage switches
do not block while parsing the entire 166,700-neuron archive.
"""

from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path


HEADER = struct.Struct("<4sII")
RECORD_HEADER = struct.Struct("<qI")
NODE = struct.Struct("<ffffi")


def build(source: Path, output: Path, report: Path, stride: int) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    with source.open("rb") as src:
        magic, version, count = HEADER.unpack(src.read(HEADER.size))
        if magic != b"FWBR" or version != 1:
            raise ValueError(f"unsupported branch stream header: {magic!r} v{version}")
        selected = 0
        total_nodes = 0
        with output.open("wb+") as dst:
            dst.write(HEADER.pack(b"FWBR", 1, 0))
            for record_index in range(count):
                header = src.read(RECORD_HEADER.size)
                if len(header) != RECORD_HEADER.size:
                    raise ValueError(f"truncated record header at {record_index}")
                body_id, node_count = RECORD_HEADER.unpack(header)
                payload_size = node_count * NODE.size
                payload = src.read(payload_size)
                if len(payload) != payload_size:
                    raise ValueError(f"truncated record payload at {record_index}")
                if record_index % stride != 0:
                    continue
                dst.write(header)
                dst.write(payload)
                selected += 1
                total_nodes += node_count
            dst.seek(0)
            dst.write(HEADER.pack(b"FWBR", 1, selected))
    report.write_text(
        json.dumps(
            {
                "source": str(source).replace("\\", "/"),
                "output": str(output).replace("\\", "/"),
                "source_skeleton_count": count,
                "runtime_skeleton_count": selected,
                "runtime_display_nodes": total_nodes,
                "stride": stride,
                "source_file_retained": source.is_file(),
                "complete_source_preserved": False,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--stride", type=int, default=14)
    args = parser.parse_args()
    if args.stride < 1:
        raise SystemExit("--stride must be >= 1")
    build(args.source, args.output, args.report, args.stride)


if __name__ == "__main__":
    main()
