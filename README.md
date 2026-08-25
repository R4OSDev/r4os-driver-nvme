# NVME.R4D

`NVME.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.1.4`
- Image target: `/R4OS/DRIVERS/NVME.R4D`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

NVME.R4D is the canonical NVMe controller owner and the first hardware user of
the version-2 asynchronous storage contract. It scans every supported PCI NVMe
function and the complete active-namespace list, negotiates SQ/CQ pairs, clamps
ring capacity to CAP.MQES, and exposes one backend per usable namespace.

Runtime I/O keeps several commands in flight with generation-bound CIDs,
segmented streaming DMA, PRP1/PRP2 or a bounded PRP-list page, batched SQ
doorbells, and batched CQ drainage. The finite polling/deferred-work path is
also the safe fallback when interrupts or extra queue pairs are unavailable.
Pre-scheduler block scans use the same queues through the synchronous version-1
callbacks and switch to nonblocking submission when the block worker is live.

CAP.TO-derived monotonic deadlines bound controller transitions; Admin and I/O
completions have separate finite deadlines. Timeout and cancellation run
through best-effort Abort and, when required, a controller reset that changes
controller, namespace, queue, and slot generations before queues are rebuilt.
Every accepted request receives exactly one terminal result; failed recovery
leaves the backend explicitly failed and retains unsafe DMA ownership.

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
