mod codec;

use codec::{VoiceDecoder, VoiceEncoder, BITRATE, FRAME_SAMPLES};
use godot::prelude::*;

struct VoiceOpusExt;

#[gdextension]
unsafe impl ExtensionLibrary for VoiceOpusExt {}

// ---------------------------------------------------------------------------
// OpusVoiceEncoder
// ---------------------------------------------------------------------------

#[derive(GodotClass)]
#[class(base = RefCounted)]
struct OpusVoiceEncoder {
    base: Base<RefCounted>,
    enc: VoiceEncoder,
}

#[godot_api]
impl IRefCounted for OpusVoiceEncoder {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            enc: VoiceEncoder::new(BITRATE),
        }
    }
}

#[godot_api]
impl OpusVoiceEncoder {
    /// pcm: mono f32 samples (FRAME_SAMPLES long) → encoded Opus frame bytes.
    ///
    /// Precondition: `pcm` must be exactly `FRAME_SAMPLES` (960) mono samples —
    /// one 20 ms frame. A wrong-sized slice yields an empty frame, since libopus
    /// rejects non-standard frame sizes.
    #[func]
    fn encode(&mut self, pcm: PackedFloat32Array) -> PackedByteArray {
        let encoded = self.enc.encode(pcm.as_slice());
        PackedByteArray::from(encoded.as_slice())
    }
}

// ---------------------------------------------------------------------------
// OpusVoiceDecoder
// ---------------------------------------------------------------------------

#[derive(GodotClass)]
#[class(base = RefCounted)]
struct OpusVoiceDecoder {
    base: Base<RefCounted>,
    dec: VoiceDecoder,
}

#[godot_api]
impl IRefCounted for OpusVoiceDecoder {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            dec: VoiceDecoder::new(),
        }
    }
}

#[godot_api]
impl OpusVoiceDecoder {
    /// frame: Opus bytes → mono f32 samples (FRAME_SAMPLES long).
    #[func]
    fn decode(&mut self, frame: PackedByteArray) -> PackedFloat32Array {
        let pcm = self.dec.decode(frame.as_slice());
        PackedFloat32Array::from(pcm.as_slice())
    }

    #[func]
    fn frame_samples(&self) -> i64 {
        FRAME_SAMPLES as i64
    }
}
