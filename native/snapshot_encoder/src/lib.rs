mod enc_core;
mod wire;

use enc_core::EncoderCore;
use godot::prelude::*;

struct SnapshotEncoderExt;

#[gdextension]
unsafe impl ExtensionLibrary for SnapshotEncoderExt {}

/// Server-side snapshot delta encoder + native baseline history (ADR-0003).
/// Owns no gameplay rules — pure codec + ack bookkeeping (ADR-0006 leaf rule).
#[derive(GodotClass)]
#[class(base = RefCounted)]
struct NativeSnapshotEncoder {
    base: Base<RefCounted>,
    core: EncoderCore,
}

#[godot_api]
impl IRefCounted for NativeSnapshotEncoder {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, core: EncoderCore::new() }
    }
}

#[godot_api]
impl NativeSnapshotEncoder {
    #[func]
    fn set_msg_id(&mut self, id: i64) {
        self.core.set_msg_id(id as u8);
    }

    /// Returns false on ragged columns (caller must fall back to the reference encoder).
    #[func]
    fn begin_tick(&mut self, tick: i64, ids: PackedInt32Array, fields: PackedInt32Array,
            vids: PackedInt32Array, vfields: PackedInt32Array,
            vseats: PackedInt32Array, vseat_off: PackedInt32Array) -> bool {
        match self.core.begin_tick(tick as u32, ids.as_slice(), fields.as_slice(),
                vids.as_slice(), vfields.as_slice(), vseats.as_slice(), vseat_off.as_slice()) {
            Ok(()) => true,
            Err(e) => {
                godot_error!("[native-enc] begin_tick: {e}");
                false
            }
        }
    }

    /// Empty return = internal failure (caller falls back — see snapshot send integration).
    #[func]
    fn encode_for(&mut self, client_id: i64, seq: i64, want_baseline_seq: i64,
            last_input_tick: i64, interest_ids: PackedInt32Array,
            interest_vids: PackedInt32Array) -> PackedByteArray {
        match self.core.encode_for(client_id as i32, seq, want_baseline_seq,
                last_input_tick as u32, interest_ids.as_slice(), interest_vids.as_slice()) {
            Ok(v) => PackedByteArray::from(v.as_slice()),
            Err(e) => {
                godot_error!("[native-enc] encode_for(client {client_id}): {e}");
                PackedByteArray::new()
            }
        }
    }

    #[func]
    fn on_ack(&mut self, client_id: i64, acked_seq: i64) {
        self.core.on_ack(client_id as i32, acked_seq);
    }

    #[func]
    fn remove_client(&mut self, client_id: i64) {
        self.core.remove_client(client_id as i32);
    }

    #[func]
    fn drop_entity_from_baselines(&mut self, entity_id: i64) {
        self.core.drop_entity_from_baselines(entity_id as i32);
    }

    #[func]
    fn reset(&mut self) {
        self.core.reset();
    }

    // test/telemetry introspection
    #[func]
    fn history_len(&self, client_id: i64) -> i64 {
        self.core.history_len(client_id as i32) as i64
    }

    #[func]
    fn live_tick_count(&self) -> i64 {
        self.core.live_tick_count() as i64
    }
}
