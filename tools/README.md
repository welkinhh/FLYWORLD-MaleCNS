# Data and release tools

Run commands from the repository root. Install optional dependencies with
`python -m pip install -r tools/requirements.txt`.

These tools reproduce runtime assets; players do not need to run them.

| Tool | Purpose |
| --- | --- |
| `fetch_morphology.py` | Download the labelled SWC catalog |
| `fetch_full_malecns.py`, `fetch_full_l1em.py` | Download optional full skeleton caches |
| `build_full_branch_lod.py`, `build_full_l1em_branch_lod.py` | Convert cached skeletons to branch streams |
| `build_runtime_branch_lod.py` | Sample an adult branch stream for runtime display |
| `build_connectome_edges.py` | Generate the adult connection-edge display asset |
| `build_larva_model.py` | Rebuild the committed larval model from a paper archive |
| `validate_morphology_coverage.py` | Inspect morphology coverage and missing data |
| `build_windows.ps1` | Export the game and package the neural service |

Larval rebuild (original source and hash: `docs/DATA_PROVENANCE.md`):

```powershell
python tools/build_larva_model.py --source C:/Downloads/Supplementary-Data-S1.zip
```

Downloaded SWCs and adult model files belong in ignored `data/` subdirectories.
Generated reports and release archives belong in ignored `build/`. Runtime
assets in `assets/morphology/` are deliberate derivatives, not duplicate backups.
