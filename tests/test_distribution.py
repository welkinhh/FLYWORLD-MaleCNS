import hashlib
import json
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "brain_service"))
from brain_service import LARVA_DATA_DIR, LarvaBrain, _morphology_coverage, _process_exists


class DistributionTests(unittest.TestCase):
    def test_parent_watcher_recognizes_this_process(self):
        self.assertTrue(_process_exists(os.getpid()))

    def test_larva_runs_from_committed_data(self):
        brain = LarvaBrain(LARVA_DATA_DIR)
        ids = set(brain.ids)
        total = 0
        for seq in range(1, 61):
            result = brain.step({"fly_id": "TEST", "life_stage": "larva", "seq": seq,
                                 "inputs": {"sugar": 0.9, "hunger": 0.6}})
            activity = result["activity"]
            self.assertTrue(set(activity["spike_ids"]).issubset(ids))
            total += activity["fired_count"]
        self.assertGreater(total, 0)

    def test_committed_assets_match_source_lock(self):
        lock = json.loads((ROOT / "SOURCES.lock.json").read_text(encoding="utf-8"))
        for source in lock["sources"]:
            for path_key, hash_key in [("asset", "asset_sha256"),
                                       ("connectome_asset", "connectome_asset_sha256")]:
                if path_key in source and hash_key in source:
                    asset = ROOT / source[path_key]
                    with self.subTest(asset=source[path_key]):
                        self.assertEqual(hashlib.sha256(asset.read_bytes()).hexdigest(),
                                         source[hash_key])

    def test_adult_subset_is_reported_incomplete(self):
        coverage = _morphology_coverage("MaleCNS-v1.0", "adult")
        self.assertFalse(coverage["complete"])
        self.assertLess(coverage["runtime_branch_lod_skeleton_count"],
                        coverage["expected_neuron_count"])


if __name__ == "__main__":
    unittest.main()
