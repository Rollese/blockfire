# snapshot_encoder — native snapshot delta encoder (ADR-0003)

Rust `gdext` module that replaces the GDScript snapshot encode hot path with a byte-identical
native encoder + native per-client baseline history. Server-side, Linux x86_64 only.

Build: `cargo build --release` in this directory (binary is gitignored; Godot loads it via
`snapshot_encoder.gdextension`). Tests: `cargo test`.

When the `.so` is absent the server falls back to the GDScript reference encoder
(`shared/net/snapshot.gd`) — slower but identical on the wire.
