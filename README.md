# NVME.R4D

`NVME.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.1.3`
- Image target: `/R4OS/DRIVERS/NVME.R4D`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

NVME.R4D is the canonical NVMe controller owner. Controller transitions use
CAP.TO-derived monotonic deadlines; Admin and I/O completions have separate
finite deadlines. An I/O timeout runs through best-effort Abort, controller
reset, queue rebuild, and at most one replay before the backend is either ready
again or explicitly failed.

## Build

On Windows:

    Build.bat

Deterministic deadline and recovery-state tests:

    Build.bat test

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
