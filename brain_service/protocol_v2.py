"""Validation helpers for the FLYWORLD observation protocol v2.

v2 keeps the v1 selection/session guards and adds an explicit separation
between ecological world time, model time, and wall-clock compute latency.
Sparse activity is addressed by source neuron ID and carries model timestamps;
the client must never infer a travelling signal from a render effect.
"""

from __future__ import annotations

import math
from typing import Any


PROTOCOL_VERSION = 2


class ProtocolError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


REQUIRED_SENSORY_FIELDS = (
    "protocol_version",
    "type",
    "world_uuid",
    "epoch",
    "selection_session",
    "fly_id",
    "life_stage",
    "dataset_id",
    "model_version",
    "seq",
    "sim_time_s",
    "window_start_s",
    "window_end_s",
    "input_world_time_s",
    "requested_model_dt_s",
)


def _finite_number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        raise ProtocolError("invalid_number", f"{name} must be a finite number")
    return float(value)


def _bounded(value: Any, name: str, low: float = 0.0, high: float = 1.0) -> float:
    number = _finite_number(value, name)
    if number < low or number > high:
        raise ProtocolError("out_of_range", f"{name} must be in [{low}, {high}]")
    return number


def _non_negative_integer(value: Any, name: str) -> None:
    number = _finite_number(value, name)
    if number < 0 or int(number) != number:
        raise ProtocolError("invalid_sequence", f"{name} must be a non-negative integer")


def validate_sensory_message(message: dict[str, Any]) -> None:
    if not isinstance(message, dict):
        raise ProtocolError("invalid_message", "message must be an object")
    missing = [field for field in REQUIRED_SENSORY_FIELDS if field not in message]
    if missing:
        raise ProtocolError("missing_field", "missing fields: " + ", ".join(missing))
    if int(message["protocol_version"]) != PROTOCOL_VERSION:
        raise ProtocolError("protocol_version", "unsupported protocol_version")
    if message["type"] not in ("step", "sensory"):
        raise ProtocolError("message_type", "expected sensory message")
    for field in ("world_uuid", "fly_id", "life_stage", "dataset_id", "model_version"):
        if not isinstance(message[field], str) or not message[field]:
            raise ProtocolError("invalid_identifier", f"{field} must be a non-empty string")
    if message["life_stage"] not in ("adult", "larva"):
        raise ProtocolError("unsupported_stage", "only adult and larva brains can be observed")
    for field in ("epoch", "selection_session", "seq"):
        _non_negative_integer(message[field], field)
    start = _finite_number(message["window_start_s"], "window_start_s")
    end = _finite_number(message["window_end_s"], "window_end_s")
    if end < start:
        raise ProtocolError("invalid_window", "window_end_s must not precede window_start_s")
    _finite_number(message["sim_time_s"], "sim_time_s")
    _finite_number(message["input_world_time_s"], "input_world_time_s")
    requested_dt = _finite_number(message["requested_model_dt_s"], "requested_model_dt_s")
    if requested_dt <= 0.0 or requested_dt > 0.1:
        raise ProtocolError("invalid_model_dt", "requested_model_dt_s must be in (0, 0.1]")
    normalized = message.get("normalized_inputs", {})
    if not isinstance(normalized, dict):
        raise ProtocolError("invalid_inputs", "normalized_inputs must be an object")
    for name in (
        "sugar",
        "food_odor",
        "food_contact_taste",
        "bitter",
        "hunger",
        "proximity",
        "stress",
        "rival_fear",
        "temperature",
        "humidity",
        "light",
        "threat_left",
        "threat_right",
        "threat_approach",
    ):
        _bounded(normalized.get(name, 0.0), f"normalized_inputs.{name}")
    inputs = message.get("inputs", {})
    if not isinstance(inputs, dict) or len(inputs) > 48:
        raise ProtocolError("invalid_inputs", "inputs must be a bounded object")


def validate_activity(activity: dict[str, Any]) -> None:
    if not isinstance(activity, dict):
        raise ProtocolError("invalid_activity", "activity must be an object")
    _non_negative_integer(activity.get("request_seq", 0), "activity.request_seq")
    start = _finite_number(activity.get("model_start_s", activity.get("window_start_s", 0.0)), "activity.model_start_s")
    end = _finite_number(activity.get("model_end_s", activity.get("window_end_s", 0.0)), "activity.model_end_s")
    if end < start:
        raise ProtocolError("invalid_window", "activity model_end_s must not precede model_start_s")
    actual_dt = _finite_number(activity.get("actual_model_dt_s", end - start), "activity.actual_model_dt_s")
    if actual_dt <= 0.0 or not math.isclose(actual_dt, end - start, rel_tol=1e-4, abs_tol=1e-9):
        raise ProtocolError("invalid_model_dt", "activity.actual_model_dt_s must match model window")
    _finite_number(activity.get("input_world_time_s", activity.get("window_end_s", 0.0)), "activity.input_world_time_s")
    _finite_number(activity.get("compute_latency_ms", 0.0), "activity.compute_latency_ms")
    rates = activity.get("neuron_rates_hz", {})
    if not isinstance(rates, dict) or len(rates) > 200000:
        raise ProtocolError("invalid_activity", "neuron_rates_hz must be a bounded object")
    for neuron_id, rate in rates.items():
        if not isinstance(neuron_id, str) or not neuron_id:
            raise ProtocolError("invalid_neuron_id", "neuron IDs must be strings")
        _bounded(rate, f"neuron_rates_hz[{neuron_id}]", 0.0, float("inf"))
    spikes = activity.get("spike_events", [])
    if not isinstance(spikes, list) or len(spikes) > 250000:
        raise ProtocolError("invalid_activity", "spike_events must be a bounded array")
    for spike in spikes:
        if not isinstance(spike, dict) or not isinstance(spike.get("neuron_id"), (str, int)):
            raise ProtocolError("invalid_spike", "each spike needs a source neuron_id")
        _finite_number(spike.get("model_time_s"), "spike.model_time_s")


def validate_response(response: dict[str, Any]) -> None:
    if not isinstance(response, dict):
        raise ProtocolError("invalid_response", "response must be an object")
    if "protocol_version" in response and int(response["protocol_version"]) != PROTOCOL_VERSION:
        raise ProtocolError("protocol_version", "unsupported response protocol_version")
    if response.get("type") != "step_ack":
        return
    activity = response.get("activity")
    if activity is not None:
        validate_activity(activity)
