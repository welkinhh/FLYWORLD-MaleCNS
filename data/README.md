# Local download cache

This directory holds optional downloads, never runtime source assets.

- `malecns/`: adult model files downloaded by `flybrain download --data data/malecns`.
- `morphology_raw/`: SWC download cache used by the tools in `tools/`.

Both are ignored by Git. The small larval runtime matrix is committed under
`brain_service/data/larva/`. Original paper archives are supplied externally to
the rebuild tools and are not kept in the source tree.
