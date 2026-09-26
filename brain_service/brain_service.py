"""Local neural service for FLYWORLD.

The proxy mode uses only Python's standard library. The MaleCNS mode uses the
installed flybrain package and its prebuilt MaleCNS v1.0 sparse connectome.
Both modes share a local WebSocket JSON protocol used by the Godot client.
"""

from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import json
import math
import os
import re
import socketserver
import struct
import threading
import time
from pathlib import Path
from typing import Any

try:
    from .protocol_v2 import PROTOCOL_VERSION, ProtocolError, validate_response, validate_sensory_message
except ImportError:
    from protocol_v2 import PROTOCOL_VERSION, ProtocolError, validate_response, validate_sensory_message

MODEL_DT_SECONDS = 0.001
LARVA_DATA_DIR = Path(__file__).resolve().parent / "data" / "larva"


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def _morphology_coverage(dataset_id: str, life_stage: str) -> dict[str, Any]:
    """Report the asset boundary instead of implying complete morphology."""
    if life_stage == "larva":
        return {
            "dataset_id": dataset_id,
            "expected_neuron_count": 444,
            "actual_loaded_neuron_count": 444,
            "actual_loaded_branch_skeleton_count": 3,
            "branch_lod_skeleton_count": 444,
            "branch_lod_display_nodes": 21312,
            "runtime_branch_lod_skeleton_count": 444,
            "runtime_branch_lod_display_nodes": 21312,
            "expected_skeletons": ["29", "11995", "23233"],
            "actual_loaded_skeletons": ["29", "11995", "23233"],
            "missing_report": "All 444 L1EM SWC skeletons are present in larva_full_branches.bin; the JSON catalog retains three semantic labels.",
            "complete": True,
        }
    return {
        "dataset_id": dataset_id,
        "expected_neuron_count": 166700,
        "actual_loaded_neuron_count": 140638,
        "actual_loaded_position_count": 140638,
        "actual_loaded_branch_skeleton_count": 10,
        "branch_lod_skeleton_count": 11908,
        "branch_lod_display_nodes": 563722,
        "runtime_branch_lod_skeleton_count": 11908,
        "runtime_branch_lod_display_nodes": 563722,
        "detailed_catalog_complete": False,
        "position_centers_complete": False,
        "expected_skeletons": "MaleCNS full CNS skeleton catalog",
        "actual_loaded_skeletons": ["10001", "10010", "10045", "10056", "10360", "523769", "10763", "11288", "25582", "35051"],
        "missing_report": "Runtime assets contain 140,638 neuron centers, 11,908 sampled skeletons and ten detailed labelled neurons; complete adult morphology is not bundled.",
        "complete": False,
    }


def _activity_timing(request: dict[str, Any], model_start: float, model_end: float, started_at: float, input_world_time: float) -> dict[str, Any]:
    return {
        "model_start_s": float(model_start),
        "model_end_s": float(model_end),
        "actual_model_dt_s": float(max(0.0, model_end - model_start)),
        "input_world_time_s": float(input_world_time),
        "requested_model_dt_s": float(request.get("requested_model_dt_s", MODEL_DT_SECONDS)),
        "compute_latency_ms": max(0.0, (time.perf_counter() - started_at) * 1000.0),
    }


class ProxyBrain:
    """Small stateful adapter with the same contract as the Godot adapter."""

    def __init__(self) -> None:
        self.states: dict[str, dict[str, float]] = {}
        self.model_time: dict[str, float] = {}

    def state_for(self, fly_id: str) -> dict[str, float]:
        return self.states.setdefault(
            fly_id,
            {"sugar": 0.04, "bitter": 0.02, "approach": 0.05, "threat": 0.05, "motor": 0.02},
        )

    def step(self, fly_id: str, inputs: dict[str, Any], dt: float) -> dict[str, float]:
        previous = self.state_for(fly_id)
        sugar = float(inputs.get("sugar", 0.0))
        bitter = float(inputs.get("bitter", 0.0))
        hunger = float(inputs.get("hunger", 0.0))
        proximity = float(inputs.get("proximity", 0.0))
        stress = float(inputs.get("stress", 0.0))
        rival_fear = float(inputs.get("rival_fear", 0.0))
        response_rate = clamp(dt * 12.0, 0.05, 0.45)
        approach_target = clamp(sugar * 0.72 + hunger * 0.5 - bitter * 0.88, -1.0, 1.0)
        threat_target = clamp(proximity * 0.58 + stress * 0.48 + rival_fear * 0.45, 0.0, 1.0)
        motor_target = clamp(abs(approach_target) * 0.55 + threat_target * 0.45, 0.0, 1.0)

        def smooth(key: str, target: float, factor: float = response_rate) -> float:
            previous[key] = previous[key] + (target - previous[key]) * factor
            return previous[key]

        smooth("sugar", sugar)
        smooth("bitter", bitter)
        smooth("approach", approach_target, response_rate * 0.82)
        smooth("threat", threat_target, response_rate * 0.9)
        smooth("motor", motor_target)
        return dict(previous)

    def handle(self, request: dict[str, Any]) -> dict[str, Any]:
        request_type = request.get("type")
        if request_type == "hello":
            return {
                "type": "hello",
                "protocol": PROTOCOL_VERSION,
                "protocol_version": PROTOCOL_VERSION,
                "mode": "local_proxy",
                "model": "python_proxy_v1",
                "model_version": "python_proxy_v1",
                "dataset_id": "local-proxy",
                "outputs": ["sugar", "bitter", "approach", "threat", "motor"],
            }
        if request_type == "ping":
            return {"type": "pong", "protocol": PROTOCOL_VERSION, "protocol_version": PROTOCOL_VERSION}
        if request_type == "reset":
            fly_id = str(request.get("fly_id", ""))
            if fly_id:
                self.states.pop(fly_id, None)
                self.model_time.pop(fly_id, None)
            else:
                self.states.clear()
                self.model_time.clear()
            return {"type": "reset_ack", "protocol": PROTOCOL_VERSION, "protocol_version": PROTOCOL_VERSION, "fly_id": fly_id or None}
        if request_type == "cancel":
            fly_id = str(request.get("fly_id", ""))
            if fly_id:
                self.states.pop(fly_id, None)
                self.model_time.pop(fly_id, None)
            return {"type": "cancel_ack", "protocol": PROTOCOL_VERSION, "protocol_version": PROTOCOL_VERSION, "fly_id": fly_id or None}
        if request_type in ("step", "sensory"):
            started_at = time.perf_counter()
            fly_id = str(request.get("fly_id", ""))
            if not fly_id:
                raise ValueError("step requires fly_id")
            dt = clamp(float(request.get("dt", 0.05)), 0.001, 0.25)
            inputs = request.get("inputs", {})
            if not isinstance(inputs, dict):
                raise ValueError("inputs must be an object")
            model_start = self.model_time.get(fly_id, 0.0)
            model_end = model_start + dt
            self.model_time[fly_id] = model_end
            timing = _activity_timing(request, model_start, model_end, started_at, float(request.get("input_world_time_s", request.get("sim_time_s", 0.0))))
            return {
                "type": "step_ack",
                "protocol": PROTOCOL_VERSION,
                "protocol_version": PROTOCOL_VERSION,
                "world_uuid": str(request.get("world_uuid", "")),
                "epoch": int(request.get("epoch", 0)),
                "selection_session": int(request.get("selection_session", 0)),
                "fly_id": fly_id,
                "life_stage": str(request.get("life_stage", "adult")),
                "dataset_id": "local-proxy",
                "model_version": "python_proxy_v1",
                "seq": int(request.get("seq", 0)),
                "sim_time_s": float(request.get("sim_time_s", 0.0)),
                "window_start_s": float(request.get("window_start_s", 0.0)),
                "window_end_s": float(request.get("window_end_s", request.get("sim_time_s", 0.0))),
                **timing,
                "activity": {
                    "request_seq": int(request.get("seq", 0)),
                    "dataset": "local-proxy",
                    "dataset_id": "local-proxy",
                    "model_version": "python_proxy_v1",
                    "window_start_s": float(request.get("window_start_s", 0.0)),
                    "window_end_s": float(request.get("window_end_s", request.get("sim_time_s", 0.0))),
                    "window_ms": dt * 1000.0,
                    "neuron_rates_hz": {},
                    "spike_events": [],
                    "morphology_coverage": _morphology_coverage("local-proxy", str(request.get("life_stage", "adult"))),
                    **timing,
                },
                "brain": self.step(fly_id, inputs, dt),
            }
        raise ValueError(f"unknown request type: {request_type!r}")


class LarvaBrain:
    """NumPy LIF adapter over the published Winding L1EM count matrix."""

    def __init__(self, data: str | Path, dt: float = 0.02) -> None:
        import numpy as np

        self.np = np
        self.dt = float(dt)
        data_path = Path(data)
        with np.load(data_path / "l1em_connectome.npz", allow_pickle=False) as archive:
            self.ids = archive["ids"].astype(str)
            self.weights = archive["weights"].astype(np.float32)
            self.groups = {
                name: archive[name].astype(np.int32)
                for name in ("orn", "pn", "kc", "apl", "ln", "mbon", "dan")
            }
        self.id_to_index = {neuron_id: index for index, neuron_id in enumerate(self.ids)}
        self.v = np.zeros(len(self.ids), dtype=np.float32)
        self.last_spikes = np.empty(0, dtype=np.int32)
        self.model_time = 0.0
        self.active_fly_id: str | None = None
        self.display_ids = ("29", "11995", "23233")
        self.display_indices = {neuron_id: self.id_to_index[neuron_id] for neuron_id in self.display_ids if neuron_id in self.id_to_index}

    def reset(self) -> None:
        self.v.fill(0.0)
        self.last_spikes = self.np.empty(0, dtype=self.np.int32)
        self.model_time = 0.0

    @staticmethod
    def _activity(count: int, scale: float = 4.0) -> float:
        return clamp(1.0 - math.exp(-count / max(scale, 1.0)), 0.0, 1.0)

    def step(self, request: dict[str, Any]) -> dict[str, Any]:
        started_at = time.perf_counter()
        fly_id = str(request["fly_id"])
        if self.active_fly_id != fly_id:
            self.reset()
            self.active_fly_id = fly_id
        inputs = request.get("inputs", {})
        model_start = self.model_time
        model_end = model_start + self.dt
        self.model_time = model_end
        sugar = clamp(float(inputs.get("food_odor", inputs.get("sugar", 0.0))), 0.0, 1.0)
        contact_taste = clamp(float(inputs.get("food_contact_taste", 0.0)), 0.0, 1.0)
        bitter = clamp(float(inputs.get("bitter", 0.0)), 0.0, 1.0)
        hunger = clamp(float(inputs.get("hunger", 0.0)), 0.0, 1.0)
        stress = clamp(float(inputs.get("stress", 0.0)), 0.0, 1.0)
        proximity = clamp(float(inputs.get("proximity", 0.0)), 0.0, 1.0)
        threat_left = clamp(float(inputs.get("threat_left", 0.0)), 0.0, 1.0)
        threat_right = clamp(float(inputs.get("threat_right", 0.0)), 0.0, 1.0)
        threat_approach = clamp(float(inputs.get("threat_approach", 0.0)), 0.0, 1.0)
        drive = self.np.zeros(len(self.ids), dtype=self.np.float32)
        drive[self.groups["orn"]] += (sugar * 1.25 + contact_taste * 0.55 - bitter * 1.1)
        drive[self.groups["ln"]] += (bitter * 0.2 + stress * 0.28)
        drive[self.groups["dan"]] += (stress * 0.35 + proximity * 0.2 + threat_approach * 0.3 + abs(threat_left - threat_right) * 0.08)
        previous_spikes = self.np.zeros(len(self.ids), dtype=self.np.float32)
        if self.last_spikes.size:
            previous_spikes[self.last_spikes] = 1.0
        recurrent = self.weights @ previous_spikes
        self.v = self.v * 0.86 + recurrent * 0.60 + drive * 0.10
        spikes = self.np.flatnonzero(self.v >= 0.40).astype(self.np.int32)
        self.v[spikes] = 0.0
        self.last_spikes = spikes
        orn_count = int(self.np.isin(spikes, self.groups["orn"]).sum())
        mbon_count = int(self.np.isin(spikes, self.groups["mbon"]).sum())
        dan_count = int(self.np.isin(spikes, self.groups["dan"]).sum())
        kc_count = int(self.np.isin(spikes, self.groups["kc"]).sum())
        signed_taste = sugar - bitter
        brain = {
            "sugar": clamp(sugar * 0.35 + self._activity(orn_count, 5.0) * 0.65, 0.0, 1.0),
            "bitter": clamp(bitter * 0.35 + max(0.0, -signed_taste) * 0.65, 0.0, 1.0),
            "approach": clamp(max(0.0, signed_taste) * 0.35 + self._activity(mbon_count + kc_count, 7.0) * 0.65 + hunger * 0.15, 0.0, 1.0),
            "threat": clamp(stress * 0.35 + proximity * 0.2 + self._activity(dan_count, 5.0) * 0.45, 0.0, 1.0),
            "motor": clamp((len(spikes) / 32.0) + stress * 0.1, 0.0, 1.0),
        }
        spike_set = set(spikes.tolist())
        neuron_rates = {
            neuron_id: float(1.0 / self.dt) if neuron_id in self.display_indices and self.display_indices[neuron_id] in spike_set else 0.0
            for neuron_id in self.display_ids
        }
        return {
            "type": "step_ack",
            "protocol": PROTOCOL_VERSION,
            "protocol_version": PROTOCOL_VERSION,
            "world_uuid": str(request.get("world_uuid", "")),
            "epoch": int(request.get("epoch", 0)),
            "selection_session": int(request.get("selection_session", 0)),
            "fly_id": fly_id,
            "life_stage": "larva",
            "dataset_id": "Winding2023-L1EM",
            "model_version": "L1EM connectome LIF-lite v1",
            "seq": int(request.get("seq", 0)),
            "sim_time_s": float(request.get("sim_time_s", 0.0)),
            "window_start_s": float(request.get("window_start_s", 0.0)),
            "window_end_s": float(request.get("window_end_s", 0.0)),
            **_activity_timing(request, model_start, model_end, started_at, float(request.get("input_world_time_s", request.get("sim_time_s", 0.0)))),
            "brain": brain,
            "backend": "winding2023_l1em_lif",
            "activity": {
                "request_seq": int(request.get("seq", 0)),
                "dataset": "Winding 2023 L1EM",
                "dataset_id": "Winding2023-L1EM",
                "model_version": "L1EM connectome LIF-lite v1",
                "window_start_s": float(request.get("window_start_s", 0.0)),
                "window_end_s": float(request.get("window_end_s", 0.0)),
                "window_ms": self.dt * 1000.0,
                "neuron_rates_hz": neuron_rates,
                "spike_ids": [str(self.ids[i]) for i in spikes],
                "fired_count": int(len(spikes)),
                "morphology_coverage": _morphology_coverage("Winding2023-L1EM", "larva"),
                **_activity_timing(request, model_start, model_end, started_at, float(request.get("input_world_time_s", request.get("sim_time_s", 0.0)))),
            },
            "telemetry": {
                "fired_count": int(len(spikes)),
                "active_experts": ["orn", "mbon", "dan"],
            },
        }


class MaleCNSBrain:
    """Adult MaleCNS plus the optional Winding L1EM larval adapter.

    The connectome stays resident in memory. Each tick only injects the
    currently selected sensory experts and reads the action experts relevant to
    the current scene. This is a routing/readout optimisation; it does not
    claim that the connectome has been pruned or retrained.
    """

    def __init__(self, data: str | Path, device: str = "cpu", dt: float = 0.02) -> None:
        import numpy as np
        from flybrain import FlyBrain

        if device != "cpu":
            raise ValueError("the FLYWORLD MaleCNS adapter currently supports device=cpu")
        self.np = np
        self.dt = float(dt)
        self.FLY_IDS: tuple[str, ...] = ()
        self.fly_index: dict[str, int] = {}
        self.active_fly_id: str | None = None
        self.brain = FlyBrain(
            data=Path(data),
            device=device,
            batch=1,
            dt=self.dt,
            sensory_input=False,
            seed=64,
            refractory=0.0022,
        )
        meta_path = Path(data) / "brain.npz"
        with self.np.load(meta_path, allow_pickle=False) as meta:
            self.neuron_ids = meta["ids"].astype(self.np.int64, copy=False)
        larva_data = LARVA_DATA_DIR
        # The larval adapter has its own calibrated 20 ms LIF-lite clock. The
        # adult MaleCNS clock can be configured independently for the finer
        # interaction mode without silently changing larval dynamics.
        self.larva_brain = LarvaBrain(larva_data, dt=0.020) if (larva_data / "l1em_connectome.npz").exists() else None
        self.input_groups = {
            "taste": self.brain.cells(["BM_Taste"]),
            "loom_left": self.brain.cells(["LC4", "LPLC2"], side="L"),
            "loom_right": self.brain.cells(["LC4", "LPLC2"], side="R"),
        }
        self.output_groups = {
            "forward": np.concatenate([self.brain.groups["forward_L"], self.brain.groups["forward_R"]]),
            "steer": np.concatenate([self.brain.groups["steer_L"], self.brain.groups["steer_R"]]),
            "escape": np.concatenate([self.brain.groups["escape_L"], self.brain.groups["escape_R"]]),
            "backward": np.concatenate([self.brain.groups["backward_L"], self.brain.groups["backward_R"]]),
            "punch": np.concatenate([self.brain.groups["punch_L"], self.brain.groups["punch_R"]]),
            "kick": np.concatenate([self.brain.groups["kick_L"], self.brain.groups["kick_R"]]),
        }
        display_ids = ["10001", "10010", "10045", "10056", "10360", "523769", "10763", "11288", "25582", "35051"]
        id_to_index = {str(int(body_id)): index for index, body_id in enumerate(self.neuron_ids)}
        self.display_indices = {body_id: id_to_index[body_id] for body_id in display_ids if body_id in id_to_index}
        self.masks = {name: self._mask(indices) for name, indices in {**self.input_groups, **self.output_groups}.items()}
        self.pending_ticks: dict[int, dict[str, dict[str, Any]]] = {}
        self.lock = threading.Lock()
        self.last_brain: dict[str, dict[str, float]] = {}
        self.model_time: dict[str, float] = {}
        self.synaptic_delay_s = 0.0018
        self.delayed_drives: dict[str, list[tuple[float, float, float, float]]] = {}
        print("MaleCNS: compiling first sparse step", flush=True)
        self.brain.step()
        self.brain.reset(seed=64)

    def _mask(self, indices: Any):
        mask = self.np.zeros(self.brain.n, dtype=self.np.bool_)
        mask[self.np.asarray(indices, dtype=self.np.int64)] = True
        return mask

    @staticmethod
    def _blank_brain() -> dict[str, float]:
        return {"sugar": 0.0, "bitter": 0.0, "approach": 0.0, "threat": 0.0, "motor": 0.0}

    def _activity(self, fired: Any, expert: str, scale: float = 4.0) -> float:
        fired_array = self.np.asarray(fired, dtype=self.np.int64)
        if fired_array.size == 0:
            return 0.0
        count = int(self.masks[expert][fired_array].sum())
        return clamp(1.0 - math.exp(-count / max(scale, 1.0)), 0.0, 1.0)

    def _step_batch(self, requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
        request_by_id = {str(request["fly_id"]): request for request in requests}
        inputs_by_id = {str(request["fly_id"]): request.get("inputs", {}) for request in requests}
        active_by_id: dict[str, list[str]] = {}
        for fly_id, fly_index in self.fly_index.items():
            inputs = inputs_by_id.get(fly_id, {})
            sugar = clamp(float(inputs.get("food_odor", inputs.get("sugar", 0.0))), 0.0, 1.0)
            bitter = clamp(float(inputs.get("bitter", 0.0)), 0.0, 1.0)
            proximity = clamp(float(inputs.get("proximity", 0.0)), 0.0, 1.0)
            stress = clamp(float(inputs.get("stress", 0.0)), 0.0, 1.0)
            rival_fear = clamp(float(inputs.get("rival_fear", 0.0)), 0.0, 1.0)
            threat_left = clamp(float(inputs.get("threat_left", 0.0)), 0.0, 1.0)
            threat_right = clamp(float(inputs.get("threat_right", 0.0)), 0.0, 1.0)
            threat_approach = clamp(float(inputs.get("threat_approach", 0.0)), 0.0, 1.0)
            taste_drive = sugar - bitter
            active: list[str] = []
            if sugar > 0.02 or bitter > 0.02:
                active.append("taste")
            if proximity > 0.08 or stress > 0.5 or rival_fear > 0.25 or threat_left > 0.02 or threat_right > 0.02 or threat_approach > 0.02:
                active.append("threat")
            if not active:
                active.append("baseline")
            active_by_id[fly_id] = active
            if "threat" in active:
                # Batch index identifies the selected fly, not its visual
                # side. Preserve the world-relative threat direction by
                # driving the two loom channels independently.
                shared_drive = proximity * 0.55 + stress * 0.18 + rival_fear * 0.15 + threat_approach * 0.22
                left_drive = shared_drive + threat_left * 0.30
                right_drive = shared_drive + threat_right * 0.30
            else:
                left_drive = 0.0
                right_drive = 0.0
            model_time = self.model_time.get(fly_id, 0.0)
            queue = self.delayed_drives.setdefault(fly_id, [])
            queue.append((model_time + self.synaptic_delay_s, taste_drive * 1.5, left_drive, right_drive))
            ready = [item for item in queue if item[0] <= model_time + self.dt]
            self.delayed_drives[fly_id] = [item for item in queue if item[0] > model_time + self.dt]
            for _due_time, delayed_taste, delayed_left, delayed_right in ready:
                if delayed_taste != 0.0:
                    self.brain.v[self.input_groups["taste"], fly_index] += delayed_taste
                if delayed_left > 0.0:
                    self.brain.v[self.input_groups["loom_left"], fly_index] += delayed_left
                if delayed_right > 0.0:
                    self.brain.v[self.input_groups["loom_right"], fly_index] += delayed_right

        fired = self.brain.step()
        if not isinstance(fired, list):
            fired = [fired]
        responses: list[dict[str, Any]] = []
        for fly_id, fly_index in self.fly_index.items():
            request = request_by_id[fly_id]
            model_start = self.model_time.get(fly_id, 0.0)
            model_end = model_start + self.dt
            self.model_time[fly_id] = model_end
            inputs = inputs_by_id.get(fly_id, {})
            sugar = clamp(float(inputs.get("food_odor", inputs.get("sugar", 0.0))), 0.0, 1.0)
            bitter = clamp(float(inputs.get("bitter", 0.0)), 0.0, 1.0)
            proximity = clamp(float(inputs.get("proximity", 0.0)), 0.0, 1.0)
            stress = clamp(float(inputs.get("stress", 0.0)), 0.0, 1.0)
            fired_for_fly = fired[fly_index]
            taste = self._activity(fired_for_fly, "taste", scale=6.0)
            forward = self._activity(fired_for_fly, "forward")
            steer = self._activity(fired_for_fly, "steer")
            escape = self._activity(fired_for_fly, "escape")
            backward = self._activity(fired_for_fly, "backward")
            punch = self._activity(fired_for_fly, "punch")
            kick = self._activity(fired_for_fly, "kick")
            signed_taste = sugar - bitter
            brain = {
                "sugar": clamp(sugar * 0.35 + taste * 0.65, 0.0, 1.0),
                "bitter": clamp(bitter * 0.35 + max(0.0, -signed_taste) * 0.65, 0.0, 1.0),
                "approach": clamp(forward * 0.55 + steer * 0.25 + max(0.0, signed_taste) * 0.2, 0.0, 1.0),
                "threat": clamp(max(escape, punch, kick) * 0.55 + proximity * 0.25 + stress * 0.2, 0.0, 1.0),
                "motor": 0.0,
            }
            brain["motor"] = clamp(max(brain["approach"], brain["threat"], backward * 0.45), 0.0, 1.0)
            self.last_brain[fly_id] = brain
            fired_count = int(len(fired_for_fly))
            neuron_rates = {
                neuron_id: float(1.0 / self.dt) if int(neuron_index) in fired_for_fly else 0.0
                for neuron_id, neuron_index in self.display_indices.items()
            }
            responses.append({
                "type": "step_ack",
                "protocol": PROTOCOL_VERSION,
                "protocol_version": PROTOCOL_VERSION,
                "world_uuid": str(request.get("world_uuid", "")),
                "epoch": int(request.get("epoch", 0)),
                "selection_session": int(request.get("selection_session", 0)),
                "fly_id": fly_id,
                "life_stage": str(request.get("life_stage", "adult")),
                "dataset_id": "MaleCNS-v1.0",
                "model_version": "MaleCNS v1.0",
                "seq": int(request.get("seq", 0)),
                "sim_time_s": float(request.get("sim_time_s", 0.0)),
                "window_start_s": float(request.get("window_start_s", 0.0)),
                "window_end_s": float(request.get("window_end_s", 0.0)),
                **_activity_timing(request, model_start, model_end, float(request.get("_started_at", time.perf_counter())), float(request.get("input_world_time_s", request.get("sim_time_s", 0.0)))),
                "brain": brain,
                "backend": "malecns_v1",
                "activity": {
                    "request_seq": int(request.get("seq", 0)),
                    "dataset": "MaleCNS v1.0",
                    "dataset_id": "MaleCNS-v1.0",
                    "model_version": "MaleCNS v1.0",
                    "window_start_s": float(request.get("window_start_s", 0.0)),
                    "window_end_s": float(request.get("window_end_s", 0.0)),
                    "window_ms": self.dt * 1000.0,
                    "neuron_rates_hz": neuron_rates,
                    # Sparse, source-ID-addressed spikes drive the whole-brain
                    # viewer without sending a dense 166k-neuron frame.
                    "spike_ids": [int(self.neuron_ids[index]) for index in fired_for_fly],
                    "readout": {
                        "forward": forward,
                        "steer": steer,
                        "escape": escape,
                        "backward": backward,
                        "punch": punch,
                        "kick": kick,
                    },
                    "morphology_coverage": _morphology_coverage("MaleCNS-v1.0", "adult"),
                    **_activity_timing(request, model_start, model_end, float(request.get("_started_at", time.perf_counter())), float(request.get("input_world_time_s", request.get("sim_time_s", 0.0)))),
                },
                "telemetry": {
                    "fired_count": fired_count,
                    "active_experts": active_by_id[fly_id],
                    "readout": {
                        "forward": forward,
                        "steer": steer,
                        "escape": escape,
                        "backward": backward,
                        "punch": punch,
                        "kick": kick,
                    },
                },
            })
        return responses

    def handle(self, request: dict[str, Any]) -> dict[str, Any] | list[dict[str, Any]]:
        request_type = request.get("type")
        if request_type == "hello":
            return {
                "type": "hello",
                "protocol": PROTOCOL_VERSION,
                "protocol_version": PROTOCOL_VERSION,
                "mode": "malecns",
                "model": "MaleCNS v1.0",
                "model_version": "MaleCNS v1.0",
                "dataset_id": "MaleCNS-v1.0",
                "stages": {
                    "adult": {"dataset_id": "MaleCNS-v1.0", "model_version": "MaleCNS v1.0"},
                    "larva": {"dataset_id": "Winding2023-L1EM", "model_version": "L1EM connectome LIF-lite v1"},
                },
                "batch": 1,
                "dt": self.dt,
                "neurons": int(self.brain.n),
                "connections": int(len(self.brain.weights)),
                "outputs": ["sugar", "bitter", "approach", "threat", "motor"],
            }
        if request_type == "ping":
            return {"type": "pong", "protocol": PROTOCOL_VERSION, "protocol_version": PROTOCOL_VERSION, "mode": "malecns"}
        if request_type == "reset":
            with self.lock:
                self.brain.reset(seed=64)
                if self.larva_brain is not None:
                    self.larva_brain.reset()
                    self.larva_brain.active_fly_id = None
                self.pending_ticks.clear()
                self.FLY_IDS = ()
                self.fly_index = {}
                self.active_fly_id = None
                self.last_brain = {}
                self.model_time.clear()
                self.delayed_drives.clear()
            return {"type": "reset_ack", "protocol": PROTOCOL_VERSION, "protocol_version": PROTOCOL_VERSION, "fly_id": request.get("fly_id")}
        if request_type == "cancel":
            with self.lock:
                if str(request.get("fly_id", "")) == self.active_fly_id:
                    self.brain.reset(seed=64)
                    if self.larva_brain is not None:
                        self.larva_brain.reset()
                    self.active_fly_id = None
                    self.FLY_IDS = ()
                    self.fly_index = {}
                    self.last_brain = {}
                    self.model_time.clear()
                    self.delayed_drives.clear()
            return {"type": "cancel_ack", "protocol": PROTOCOL_VERSION, "protocol_version": PROTOCOL_VERSION, "fly_id": request.get("fly_id")}
        if request_type in ("step", "sensory"):
            fly_id = str(request.get("fly_id", ""))
            if not fly_id:
                raise ValueError("step requires fly_id")
            if str(request.get("life_stage", "adult")) == "larva":
                if self.larva_brain is None:
                    raise ValueError("larva model unavailable")
                with self.lock:
                    return self.larva_brain.step(request)
            with self.lock:
                if self.active_fly_id != fly_id:
                    self.brain.reset(seed=64)
                    self.active_fly_id = fly_id
                    self.FLY_IDS = (fly_id,)
                    self.fly_index = {fly_id: 0}
                    self.last_brain = {fly_id: self._blank_brain()}
                    self.model_time = {fly_id: 0.0}
                    self.delayed_drives = {fly_id: []}
                request["_started_at"] = time.perf_counter()
                return self._step_batch([request])
        raise ValueError(f"unknown request type: {request_type!r}")


def _recv_exact(sock: Any, size: int) -> bytes:
    chunks: list[bytes] = []
    remaining = size
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise ConnectionError("websocket peer closed")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _recv_frame(sock: Any) -> tuple[bool, int, bytes]:
    first, second = _recv_exact(sock, 2)
    fin = bool(first & 0x80)
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", _recv_exact(sock, 8))[0]
    mask = _recv_exact(sock, 4) if masked else b""
    payload = bytearray(_recv_exact(sock, length))
    if mask:
        for index in range(length):
            payload[index] ^= mask[index % 4]
    return fin, opcode, bytes(payload)


def _send_frame(sock: Any, payload: bytes, opcode: int = 1) -> None:
    length = len(payload)
    header = bytearray([0x80 | opcode])
    if length < 126:
        header.append(length)
    elif length < 65536:
        header.append(126)
        header.extend(struct.pack("!H", length))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", length))
    sock.sendall(bytes(header) + payload)


class BrainWebSocketHandler(socketserver.BaseRequestHandler):
    def _send_json(self, payload: dict[str, Any]) -> None:
        _send_frame(
            self.request,
            json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
        )

    def _handshake(self) -> None:
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = self.request.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake closed")
            request += chunk
            if len(request) > 65536:
                raise ValueError("websocket handshake too large")
        header_text = request.decode("latin-1")
        match = re.search(r"(?im)^Sec-WebSocket-Key:\s*([^\r\n]+)", header_text)
        if match is None:
            raise ValueError("missing Sec-WebSocket-Key")
        accept = base64.b64encode(
            hashlib.sha1((match.group(1).strip() + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        ).encode("ascii")
        self.request.sendall(response)

    def _handle_request(self, request: dict[str, Any]) -> None:
        if request.get("type") in ("step", "sensory"):
            validate_sensory_message(request)
        response = self.server.brain.handle(request)  # type: ignore[attr-defined]
        if response is None:
            return
        if isinstance(response, list):
            for item in response:
                validate_response(item)
                self._send_json(item)
        else:
            validate_response(response)
            self._send_json(response)

    def handle(self) -> None:
        try:
            self._handshake()
            fragments = bytearray()
            fragment_opcode = 0
            while True:
                fin, opcode, payload = _recv_frame(self.request)
                if opcode == 0x8:
                    _send_frame(self.request, payload, opcode=0x8)
                    return
                if opcode == 0x9:
                    _send_frame(self.request, payload, opcode=0xA)
                    continue
                if opcode == 0xA:
                    continue
                if opcode == 0x0:
                    if fragment_opcode == 0:
                        raise ValueError("unexpected continuation frame")
                    fragments.extend(payload)
                    if fin:
                        if fragment_opcode == 1:
                            self._handle_request(json.loads(bytes(fragments).decode("utf-8")))
                        fragments.clear()
                        fragment_opcode = 0
                    continue
                if opcode != 0x1:
                    raise ValueError(f"unsupported websocket opcode: {opcode}")
                if fin:
                    self._handle_request(json.loads(payload.decode("utf-8")))
                else:
                    fragments = bytearray(payload)
                    fragment_opcode = opcode
        except (ConnectionError, OSError):
            return
        except ProtocolError as error:
            try:
                self._send_json({"type": "error", "protocol": PROTOCOL_VERSION, "protocol_version": PROTOCOL_VERSION, "code": error.code, "error": str(error)})
            except OSError:
                pass
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            try:
                self._send_json({"type": "error", "protocol": PROTOCOL_VERSION, "protocol_version": PROTOCOL_VERSION, "code": "invalid_request", "error": str(error)})
            except OSError:
                pass


class BrainServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, address: tuple[str, int], brain: Any) -> None:
        super().__init__(address, BrainWebSocketHandler)
        self.brain = brain


def _process_exists(pid: int) -> bool:
    if pid <= 0:
        return True
    if os.name == "nt":
        from ctypes import wintypes

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel.GetExitCodeProcess.restype = wintypes.BOOL
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel.CloseHandle.restype = wintypes.BOOL
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            # Access denied does not establish that the parent has exited.
            return ctypes.get_last_error() == 5
        try:
            exit_code = wintypes.DWORD()
            ok = kernel.GetExitCodeProcess(handle, ctypes.byref(exit_code))
            return bool(ok and exit_code.value == 259)
        finally:
            kernel.CloseHandle(handle)

    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _watch_parent(server: BrainServer, parent_pid: int) -> None:
    while True:
        time.sleep(1.0)
        if not _process_exists(parent_pid):
            server.shutdown()
            return


def self_test() -> None:
    brain = ProxyBrain()
    hello = brain.handle({"type": "hello"})
    assert hello["protocol"] == PROTOCOL_VERSION
    first = brain.handle(
        {
            "type": "step",
            "fly_id": "FLY-001",
            "dt": 0.05,
            "inputs": {"sugar": 1.0, "hunger": 0.8},
        }
    )
    second = brain.handle(
        {
            "type": "step",
            "fly_id": "FLY-002",
            "dt": 0.05,
            "inputs": {"bitter": 1.0, "proximity": 0.6, "stress": 0.4},
        }
    )
    assert first["brain"]["sugar"] > 0.04
    assert second["brain"]["bitter"] > 0.02
    assert first["fly_id"] != second["fly_id"]
    print(json.dumps({"ok": True, "hello": hello, "sample": [first, second]}, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(description="FLYWORLD local neural bridge smoke service")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--model", choices=("proxy", "malecns"), default="proxy")
    parser.add_argument("--data", type=Path)
    parser.add_argument("--device", choices=("cpu",), default="cpu")
    parser.add_argument("--dt", type=float, default=0.001, help="adult MaleCNS model step in seconds (default 1 ms)")
    parser.add_argument("--parent-pid", type=int, default=0, help="stop when the Godot parent process exits")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if args.model == "malecns":
        if args.data is None:
            parser.error("--data is required with --model malecns")
        brain = MaleCNSBrain(args.data, device=args.device, dt=args.dt)
    else:
        brain = ProxyBrain()
    with BrainServer((args.host, args.port), brain) as server:
        print(f"FLYWORLD brain service listening on {args.host}:{args.port} ({args.model})", flush=True)
        if args.parent_pid > 0:
            threading.Thread(target=_watch_parent, args=(server, args.parent_pid), daemon=True).start()
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
