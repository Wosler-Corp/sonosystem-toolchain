# Windows package definitions

Each JSON file in this directory describes one already-acquired source payload. Packaging is an explicit offline step: the package builder validates the declared source identity and provenance, but never downloads vendor content.

Generated archives, installer copies, checksums, and provenance sidecars must be written outside the Git working tree and published as immutable release assets.
