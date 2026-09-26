# FLYWORLD

[简体中文](README.md) | [English]

FLYWORLD is a Windows desktop ecology sandbox. Fruit flies forage, reproduce, develop, compete for resources, and respond to predators in a stylized 2.5D garden beneath a tree root. A new round starts with four adults in each of two color groups and caps the population at 30.

The supplied Disney-style backyard illustration fills the scene. Flies, larvae, predators, and placed sugar use cutout sprites over the artwork; the trees, grass, flowers, moss, and two rotten bananas are part of the image, with no procedural tree, fence, plant, or banana models layered on top. The ecology rules are simplified and are not a complete, experimentally validated model of fruit-fly biology.

## Download and play

1. Download the Windows x64 release from GitHub Releases and extract the entire archive.
2. Keep FLYWORLD.exe and brain_service.exe in the same folder, then double-click FLYWORLD.exe.
3. Players do not need a separate Godot or Python installation; the exported executable includes the Godot runtime and does not open the editor. If FLYWORLD.exe is beside it, run_flyworld.cmd also launches the game. The garden works without the optional brain service. Brain connection requires that service and an internet connection for its first model-data download.

The service downloads neural model data on its first start to the current Windows user's application-data directory. The data is not included in the release archive. No neural signal is fabricated when the service is disconnected.

## Controls

- Click a fly to inspect its state and events.
- Click “连接大脑” to connect the selected individual. Disconnecting clears brain activity.
- Click “放糖” or “放天敌”, then click a location in the garden.
- Click “删除天敌”, then click a spider to remove it.
- Use the mouse wheel to zoom, right-click to reset the camera, and Esc to cancel a placement tool.
- The top bar contains pause, restart, x1/x2/x5/x10 speed, temperature, humidity, and light controls.

## Run from source

Source development requires Godot 4.7. Add Godot to PATH and run this from the repository root:

    ./run_flyworld.ps1

For a custom Godot installation, set its path in PowerShell:

    $env:FLYWORLD_GODOT = "C:/Godot/Godot.exe"
    ./run_flyworld.ps1

The ecology simulation runs without Python. To run the neural service, install Python 3.10 or newer and execute these commands from the repository root:

    python -m venv .venv
    ./.venv/Scripts/python.exe -m pip install --upgrade pip
    ./.venv/Scripts/python.exe -m pip install -r requirements.txt
    ./.venv/Scripts/flybrain.exe download --data data/malecns

Godot detects .venv and brain_service/brain_service.py at startup and attempts to launch the local service. It can also be started manually:

    ./.venv/Scripts/python.exe brain_service/brain_service.py --model malecns --data data/malecns --dt 0.001 --port 8765

## Build a Windows release

Install Godot 4.7 Windows export templates, then run from the repository root:

    ./.venv/Scripts/python.exe -m pip install -r tools/requirements.txt
    ./tools/build_windows.ps1 -GodotPath "C:/Godot/Godot.exe"

The output is build/FLYWORLD-windows.zip. The script bundles the game, neural service, larval runtime data, and license files. This archive is a release artifact in the ignored build/ directory; upload it to GitHub Releases rather than the source repository.

## Brain visualization and model limits

- The adult backend uses public MaleCNS v1.0 connectome data with a numerical neural-network model.
- The larval backend uses a LIF-lite adapter over the Winding 2023 L1EM connectivity matrix.
- Activity frames map to neuron IDs in the source datasets. Brain highlights show the corresponding structures and topology paths.
- These are connectome-driven computational signals, not live recordings from a fruit fly. The visual pulse along morphology is not a measured voltage or axonal conduction-delay simulation.

## Project layout

| Path | Purpose |
| --- | --- |
| Main.tscn | Main Godot scene |
| scripts/main.gd | Ecology state, behavior, lifecycle, persistence, and UI coordination |
| scripts/garden_view_3d.gd | Backyard artwork, fly, and placeable-object sprite rendering |
| scripts/brain_view_3d.gd | Neuron morphology, connectivity, and activity visualization |
| scripts/neural_adapter.gd | Protocol adapter between Godot and the local brain service |
| brain_service/ | Python neural service and WebSocket protocol |
| assets/morphology/ | Runtime morphology catalogs and compressed data |
| assets/environment/ | Full-scene backyard illustration |
| assets/sprites/ | Fly, larva, pupa, spider, and candy sprite atlas |
| brain_service/data/larva/ | Required larval model matrix and provenance metadata |
| tests/ | Behavior, interaction, neural-data and performance checks |
| tools/ | Data rebuilding and release packaging |
| docs/ | Data provenance, neural inputs and protocol |
| data/ | Ignored local download cache |
| third_party/flybrain/ | Vendored source for the upstream flybrain runtime |

Run the deterministic regressions:

    godot --headless --path . --script res://tests/observation_regression.gd -- --flyworld-test
    godot --headless --path . --script res://tests/behavior_regression.gd -- --flyworld-test

## License and data sources

The project code is licensed under MIT. The vendored flybrain runtime retains its upstream MIT license. MaleCNS, L1EM, and other dataset sources, licenses, hashes, and conversion boundaries are documented in [DATA_PROVENANCE.md](docs/DATA_PROVENANCE.md) and [SOURCES.lock.json](SOURCES.lock.json). The project-code license does not extend to third-party scientific datasets.

Reference images, original paper archives and build caches are not distributed with source. The vendored package retains its upstream files and license. See [tools/README.md](tools/README.md) for rebuilds and [tests/README.md](tests/README.md) for validation.
