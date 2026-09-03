# NVME.R4D

`NVME.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.1.6`
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
doorbells, and batched CQ drainage. I/O CQs use message vector zero. The PCI
MSI/MSI-X route remains disabled throughout preload and is installed only by
the first asynchronous runtime request. Each IRQ masks INTMS and, for MSI-X,
the actual table entry before scheduling one finite Driver Work pass; the
worker acknowledges CQ heads before unmasking. Continuous self-reposting is
absent when message interrupts are active. Bounded polling remains only for
MSI/MSI-X or work-capacity failure, timeout, recovery, and synchronous boot I/O.
Pre-scheduler block scans use the same queues through the synchronous version-1
callbacks and switch to nonblocking submission when the block worker is live.
If such an idempotent boot read causes a transport timeout or fatal recovery,
the successfully rebuilt controller replays that read exactly once. Command,
validation, media, and DMA-preparation errors are not retried.
The backend status retains a rejected I/O completion as `0x8OOOPSSS`: `OOO`
is the PRP1 page offset, `P` indicates PRP2, and `SSS` is the unchanged NVMe
completion status. This keeps early hardware failures observable without
turning a command error into a transport retry.

CAP.TO-derived monotonic deadlines bound controller transitions; Admin and I/O
completions have separate finite deadlines. Timeout and cancellation run
through best-effort Abort and, when required, a controller reset that changes
controller, namespace, queue, and slot generations before queues are rebuilt.
Every accepted request receives exactly one terminal result; failed recovery
leaves the backend explicitly failed and retains unsafe DMA ownership. Reset
and shutdown mask the device source before queue mutation, and shutdown joins
Driver Work and unregisters MSI/MSI-X before bus mastering and DMA ownership
end.

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
