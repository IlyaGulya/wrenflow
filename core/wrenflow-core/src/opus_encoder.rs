//! OGG/Opus encoding for audio recordings.
//!
//! Encodes 16kHz mono f32 samples into an OGG/Opus file.

use ogg::writing::PacketWriteEndInfo;
use std::io::Write;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum OpusEncodeError {
    #[error("Opus encoder error: {0}")]
    Encoder(String),
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),
}

const SAMPLE_RATE: i32 = 16000;
const CHANNELS: usize = 1;
const FRAME_MS: usize = 20;
const FRAME_SIZE: usize = (SAMPLE_RATE as usize * FRAME_MS) / 1000; // 320 samples

/// Encode 16kHz mono f32 samples to OGG/Opus format.
pub fn encode_ogg_opus<W: Write>(writer: &mut W, samples: &[f32]) -> Result<(), OpusEncodeError> {
    let mut encoder = opus_rs::OpusEncoder::new(SAMPLE_RATE, CHANNELS, opus_rs::Application::Voip)
        .map_err(|e| OpusEncodeError::Encoder(e.to_string()))?;
    encoder.bitrate_bps = 24000; // 24kbps — good quality for speech
    encoder.complexity = 5;

    let serial = 1u32;
    let mut ogg_writer = ogg::writing::PacketWriter::new(writer);
    let mut granule: u64 = 0;

    // Write Opus header packet (RFC 7845).
    let header = build_opus_head();
    ogg_writer
        .write_packet(header, serial, PacketWriteEndInfo::EndPage, 0)
        .map_err(|e| OpusEncodeError::Io(std::io::Error::other(e.to_string())))?;

    // Write Opus tags packet.
    let tags = build_opus_tags();
    ogg_writer
        .write_packet(tags, serial, PacketWriteEndInfo::EndPage, 0)
        .map_err(|e| OpusEncodeError::Io(std::io::Error::other(e.to_string())))?;

    // Encode audio frames.
    let mut output_buf = vec![0u8; 4000];

    let mut offset = 0;
    while offset < samples.len() {
        let end = (offset + FRAME_SIZE).min(samples.len());
        let frame = if end - offset < FRAME_SIZE {
            // Pad last frame with silence.
            let mut padded = vec![0.0f32; FRAME_SIZE];
            padded[..end - offset].copy_from_slice(&samples[offset..end]);
            padded
        } else {
            samples[offset..end].to_vec()
        };

        let encoded_len = encoder
            .encode(&frame, FRAME_SIZE, &mut output_buf)
            .map_err(|e| OpusEncodeError::Encoder(e.to_string()))?;

        granule += FRAME_SIZE as u64;

        let is_last = offset + FRAME_SIZE >= samples.len();
        let end_info = if is_last {
            PacketWriteEndInfo::EndStream
        } else {
            PacketWriteEndInfo::NormalPacket
        };

        ogg_writer
            .write_packet(
                output_buf[..encoded_len].to_vec(),
                serial,
                end_info,
                granule,
            )
            .map_err(|e| OpusEncodeError::Io(std::io::Error::other(e.to_string())))?;

        offset += FRAME_SIZE;
    }

    Ok(())
}

/// OpusHead packet (RFC 7845 Section 5.1).
fn build_opus_head() -> Vec<u8> {
    let mut head = Vec::with_capacity(19);
    head.extend_from_slice(b"OpusHead");
    head.push(1); // version
    head.push(CHANNELS as u8); // channel count
    head.extend_from_slice(&0u16.to_le_bytes()); // pre-skip
    head.extend_from_slice(&(SAMPLE_RATE as u32).to_le_bytes()); // input sample rate
    head.extend_from_slice(&0i16.to_le_bytes()); // output gain
    head.push(0); // channel mapping family
    head
}

/// OpusTags packet (RFC 7845 Section 5.2).
fn build_opus_tags() -> Vec<u8> {
    let vendor = b"wrenflow";
    let mut tags = Vec::new();
    tags.extend_from_slice(b"OpusTags");
    tags.extend_from_slice(&(vendor.len() as u32).to_le_bytes());
    tags.extend_from_slice(vendor);
    tags.extend_from_slice(&0u32.to_le_bytes()); // no user comments
    tags
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_silence() {
        let samples = vec![0.0f32; 16000]; // 1 second of silence
        let mut buf = Vec::new();
        encode_ogg_opus(&mut buf, &samples).unwrap();
        assert!(buf.len() > 0);
        assert!(buf.len() < 16000 * 2); // Should be much smaller than WAV
                                        // Check OGG magic
        assert_eq!(&buf[..4], b"OggS");
    }

    #[test]
    fn smaller_than_wav() {
        // 3 seconds of 16kHz mono
        let samples: Vec<f32> = (0..48000).map(|i| (i as f32 * 0.01).sin() * 0.5).collect();
        let mut opus_buf = Vec::new();
        encode_ogg_opus(&mut opus_buf, &samples).unwrap();
        let wav_size = 44 + samples.len() * 2; // WAV header + 16-bit PCM
        assert!(
            opus_buf.len() < wav_size / 5,
            "Opus {} should be <5x smaller than WAV {}",
            opus_buf.len(),
            wav_size
        );
    }
}
