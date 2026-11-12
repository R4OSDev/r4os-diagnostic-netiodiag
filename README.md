# NETIOD.R4X

`NETIOD.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.1.7`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/NETIOD.R4X`
- Image scope: `test`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

## Build

On Windows:

    Build.bat

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

## Generation 2

The normal Start2/Query2 diagnostic retains the original async status/lifecycle/bad-handle assertions. Request buffers remain live until actual I/O close, including draining a busy worker after a caller timeout. New typed UDP cases check duplicate bind, empty receive, close, rebind and exact generation rejection. Optional `/ECHO IPv4 PORT` sends an independent datagram to an echo peer and checks the seven-byte prefix, original length, truncation flag and consumed suffix. It uses a single five-second operation budget and releases the owned socket/channel.
