mod enc_core;
mod wire;

use godot::prelude::*;

struct SnapshotEncoderExt;

#[gdextension]
unsafe impl ExtensionLibrary for SnapshotEncoderExt {}
