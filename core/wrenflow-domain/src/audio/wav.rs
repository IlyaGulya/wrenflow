//! WAV encoder.
//!
//! Produces **PCM Int16, mono, 16 kHz** WAV files -- the exact format that the
//! Swift `AVAudioFile` pipeline writes before handing the file to Parakeet.
//!
//! WAV format reference:
//! <https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/WAVE.html>

use std::io::{self, Write};

/// Errors that can occur during WAV encoding.
#[derive(Debug, thiserror::Error)]
pub enum WavError {
    #[error("WAV I/O error: {0}")]
    Io(#[from] io::Error),
}

/// PCM format tag (linear PCM).
const WAVE_FORMAT_PCM: u16 = 1;
/// Bytes per Int16 sample.
const BYTES_PER_SAMPLE: u32 = 2;
/// Number of output channels (mono).
const CHANNELS: u16 = 1;
/// Output sample rate.
const SAMPLE_RATE: u32 = 16_000;

/// Encode `samples` (f32, -1.0 ... +1.0) as a 16 kHz mono PCM Int16 WAV file
/// and write the complete byte stream to `writer`.
///
/// The function clamps samples to the Int16 range to avoid overflow.
pub fn encode_wav<W: Write>(writer: &mut W, samples: &[f32]) -> Result<(), WavError> {
    let num_samples = samples.len() as u32;
    let data_size = num_samples * BYTES_PER_SAMPLE;
    // RIFF chunk size = 4 ("WAVE") + 8 (fmt tag+size) + 16 (fmt data) + 8 (data tag+size) + data
    let riff_size = 4 + 8 + 16 + 8 + data_size;

    let block_align = CHANNELS as u32 * BYTES_PER_SAMPLE;
    let byte_rate = SAMPLE_RATE * block_align;

    // --- RIFF header ---
    writer.write_all(b"RIFF")?;
    writer.write_all(&riff_size.to_le_bytes())?;
    writer.write_all(b"WAVE")?;

    // --- fmt  chunk ---
    writer.write_all(b"fmt ")?;
    writer.write_all(&16u32.to_le_bytes())?; // chunk size
    writer.write_all(&WAVE_FORMAT_PCM.to_le_bytes())?;
    writer.write_all(&CHANNELS.to_le_bytes())?;
    writer.write_all(&SAMPLE_RATE.to_le_bytes())?;
    writer.write_all(&byte_rate.to_le_bytes())?;
    writer.write_all(&(block_align as u16).to_le_bytes())?;
    writer.write_all(&(BYTES_PER_SAMPLE as u16 * 8).to_le_bytes())?; // bits per sample

    // --- data chunk ---
    writer.write_all(b"data")?;
    writer.write_all(&data_size.to_le_bytes())?;

    // Convert f32 -> i16 (clamp to avoid overflow)
    for &s in samples {
        let v = (s * i16::MAX as f32)
            .round()
            .clamp(i16::MIN as f32, i16::MAX as f32) as i16;
        writer.write_all(&v.to_le_bytes())?;
    }

    Ok(())
}

/// Convenience: encode to a `Vec<u8>`.
pub fn encode_wav_to_vec(samples: &[f32]) -> Result<Vec<u8>, WavError> {
    let capacity = 44 + samples.len() * 2; // 44-byte header + data
    let mut buf = Vec::with_capacity(capacity);
    encode_wav(&mut buf, samples)?;
    Ok(buf)
}

/// Parse the WAV header of a byte slice and return (sample_rate, channels,
/// bits_per_sample, data offset, data length in bytes).
///
/// Used only in tests to validate round-trip correctness.
#[cfg(test)]
fn parse_wav_header(data: &[u8]) -> (u32, u16, u16, usize, usize) {
    assert_eq!(&data[0..4], b"RIFF");
    assert_eq!(&data[8..12], b"WAVE");
    assert_eq!(&data[12..16], b"fmt ");
    let _fmt_size = u32::from_le_bytes([data[16], data[17], data[18], data[19]]);
    let _audio_fmt = u16::from_le_bytes([data[20], data[21]]);
    let channels = u16::from_le_bytes([data[22], data[23]]);
    let sample_rate = u32::from_le_bytes([data[24], data[25], data[26], data[27]]);
    let bits_per_sample = u16::from_le_bytes([data[34], data[35]]);
    assert_eq!(&data[36..40], b"data");
    let data_len = u32::from_le_bytes([data[40], data[41], data[42], data[43]]) as usize;
    (sample_rate, channels, bits_per_sample, 44, data_len)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn header_fields_correct() {
        let samples = vec![0.0f32; 16_000]; // 1 second
        let wav = encode_wav_to_vec(&samples).unwrap();

        let (sr, ch, bps, data_offset, data_len) = parse_wav_header(&wav);
        assert_eq!(sr, 16_000);
        assert_eq!(ch, 1);
        assert_eq!(bps, 16);
        assert_eq!(data_offset, 44);
        assert_eq!(data_len, 16_000 * 2); // 16 000 frames x 2 bytes
        assert_eq!(wav.len(), 44 + 16_000 * 2);
    }

    #[test]
    fn riff_size_field() {
        let samples = vec![0.5f32; 100];
        let wav = encode_wav_to_vec(&samples).unwrap();
        let riff_size = u32::from_le_bytes([wav[4], wav[5], wav[6], wav[7]]);
        // RIFF size = total file size - 8
        assert_eq!(riff_size as usize, wav.len() - 8);
    }

    #[test]
    fn silence_encodes_to_zeros() {
        let samples = vec![0.0f32; 8];
        let wav = encode_wav_to_vec(&samples).unwrap();
        // data payload starts at byte 44
        for i in 0..8 {
            let lo = wav[44 + i * 2];
            let hi = wav[44 + i * 2 + 1];
            assert_eq!((lo, hi), (0, 0), "silence sample {i} should be zero");
        }
    }

    #[test]
    fn positive_full_scale() {
        // +1.0 f32 -> i16::MAX (32767)
        let samples = vec![1.0f32];
        let wav = encode_wav_to_vec(&samples).unwrap();
        let v = i16::from_le_bytes([wav[44], wav[45]]);
        assert_eq!(v, i16::MAX);
    }

    #[test]
    fn negative_full_scale() {
        // -1.0 f32 -> -32767 (symmetric around i16::MAX)
        let samples = vec![-1.0f32];
        let wav = encode_wav_to_vec(&samples).unwrap();
        let v = i16::from_le_bytes([wav[44], wav[45]]);
        assert_eq!(v, -i16::MAX);
    }

    #[test]
    fn clamping_beyond_full_scale() {
        let samples = vec![2.0f32, -2.0f32];
        let wav = encode_wav_to_vec(&samples).unwrap();
        let v0 = i16::from_le_bytes([wav[44], wav[45]]);
        let v1 = i16::from_le_bytes([wav[46], wav[47]]);
        assert_eq!(v0, i16::MAX);
        assert_eq!(v1, i16::MIN); // -2.0 * 32767 = -65534, clamped to i16::MIN
    }

    #[test]
    fn empty_input_produces_valid_header() {
        let wav = encode_wav_to_vec(&[]).unwrap();
        assert_eq!(wav.len(), 44); // header only
        let (_, _, _, _, data_len) = parse_wav_header(&wav);
        assert_eq!(data_len, 0);
    }

    #[test]
    fn round_trip_sample_values() {
        // Generate a ramp and verify the i16 values round-trip as expected.
        let samples: Vec<f32> = (-4..=4).map(|i| i as f32 * 0.25).collect();
        let wav = encode_wav_to_vec(&samples).unwrap();
        for (i, &s) in samples.iter().enumerate() {
            let expected = (s * i16::MAX as f32)
                .round()
                .clamp(i16::MIN as f32, i16::MAX as f32) as i16;
            let actual = i16::from_le_bytes([wav[44 + i * 2], wav[44 + i * 2 + 1]]);
            assert_eq!(actual, expected, "mismatch at sample {i}");
        }
    }
}
