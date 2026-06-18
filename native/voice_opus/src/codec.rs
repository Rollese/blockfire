// Pure Opus wrapper — engine-agnostic so it is unit-testable without Godot.
use opus::{Application, Channels, Decoder, Encoder};

pub const SAMPLE_RATE: u32 = 48_000;
pub const FRAME_SAMPLES: usize = 960; // 20 ms @ 48 kHz, mono
pub const MAX_FRAME_BYTES: usize = 256;
pub const BITRATE: i32 = 24_000;

pub struct VoiceEncoder {
    enc: Encoder,
}

pub struct VoiceDecoder {
    dec: Decoder,
}

impl VoiceEncoder {
    pub fn new(bitrate: i32) -> Self {
        let mut enc =
            Encoder::new(SAMPLE_RATE, Channels::Mono, Application::Voip).unwrap();
        enc.set_bitrate(opus::Bitrate::Bits(bitrate)).unwrap();
        Self { enc }
    }

    pub fn encode(&mut self, pcm: &[f32]) -> Vec<u8> {
        let mut out = vec![0u8; MAX_FRAME_BYTES];
        let n = self.enc.encode_float(pcm, &mut out).unwrap_or(0);
        out.truncate(n);
        out
    }
}

impl VoiceDecoder {
    pub fn new() -> Self {
        Self {
            dec: Decoder::new(SAMPLE_RATE, Channels::Mono).unwrap(),
        }
    }

    pub fn decode(&mut self, frame: &[u8]) -> Vec<f32> {
        let mut out = vec![0f32; FRAME_SAMPLES];
        let n = self.dec.decode_float(frame, &mut out, false).unwrap_or(0);
        out.truncate(n);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sine_round_trips_within_rms_bound() {
        let mut enc = VoiceEncoder::new(BITRATE);
        let mut dec = VoiceDecoder::new();
        let pcm: Vec<f32> = (0..FRAME_SAMPLES)
            .map(|i| {
                (i as f32 * 2.0 * std::f32::consts::PI * 440.0 / SAMPLE_RATE as f32).sin() * 0.5
            })
            .collect();
        let frame = enc.encode(&pcm);
        assert!(
            !frame.is_empty() && frame.len() <= MAX_FRAME_BYTES,
            "encoded frame is non-empty and within size bound"
        );
        let out = dec.decode(&frame);
        assert_eq!(out.len(), FRAME_SAMPLES, "decodes a full frame");
        // Opus is lossy + has codec delay; assert it produced bounded-energy audio, not garbage.
        let rms: f32 =
            (out.iter().map(|x| x * x).sum::<f32>() / out.len() as f32).sqrt();
        assert!(rms > 0.01 && rms < 1.0, "decoded RMS {rms} in a sane band");
    }
}
