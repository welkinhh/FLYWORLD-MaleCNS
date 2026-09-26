# Validation

Run from the repository root with Godot 4.7. Always pass `--flyworld-test` to
isolate tests from user saves and automatic brain-service startup.

```powershell
godot --headless --path . --script res://tests/interaction_regression.gd -- --flyworld-test
godot --headless --path . --script res://tests/observation_regression.gd -- --flyworld-test
godot --headless --path . --script res://tests/behavior_regression.gd -- --flyworld-test
python -m unittest discover -s tests -p "test_*.py"
python tests/check_observation_signals.py
```

The interaction test exercises selection, empty clicks, placement, removal and
camera input. Observation tests use explicit activity fixtures to validate
rendering and isolation; `check_observation_signals.py` separately runs the actual
larval numerical model. Adult inference requires the downloaded MaleCNS model.

Lifecycle regressions cover fixed-step reproduction, capacity and multiple random
seeds. Surface tests cover landings and predators. Brain-edge tests inspect
optional connectivity rendering. The `*_performance.gd` scripts are benchmarks,
not correctness tests; run them with a visible renderer for meaningful timings.

Reports and optional screenshots go to ignored `build/`.

Real adult neural integration checks additionally require --flyworld-neural-test and the downloaded MaleCNS data. They are optional long-running checks.

The multiseed lifecycle regression defaults to three seeds and 300 simulated
seconds per seed. For the optional long stress run, append
--flyworld-seeds=20 --flyworld-duration=1200 after --flyworld-test.
Each completed seed prints a progress record.
