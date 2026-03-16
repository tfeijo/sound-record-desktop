/// Shared audio utility functions used by both mic_audio and system_audio.

/// Calculate RMS audio level normalized to 0.0-1.0.
pub fn calculate_rms_level(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f64 = samples.iter().map(|&s| (s as f64) * (s as f64)).sum();
    let rms = (sum_sq / samples.len() as f64).sqrt();
    (rms / 32767.0).min(1.0) as f32
}

/// Resamples audio from `from_rate` to `to_rate` using linear interpolation.
pub fn resample(samples: &[i16], from_rate: u32, to_rate: u32) -> Vec<i16> {
    if from_rate == to_rate {
        return samples.to_vec();
    }
    let ratio = from_rate as f64 / to_rate as f64;
    let output_len = ((samples.len() as f64) / ratio).ceil() as usize;
    let mut output = Vec::with_capacity(output_len);

    for i in 0..output_len {
        let src_idx = i as f64 * ratio;
        let idx_floor = src_idx.floor() as usize;
        let frac = src_idx - idx_floor as f64;

        let s0 = samples[idx_floor] as f64;
        let s1 = if idx_floor + 1 < samples.len() {
            samples[idx_floor + 1] as f64
        } else {
            s0
        };
        let interpolated = s0 + frac * (s1 - s0);
        output.push(interpolated.round() as i16);
    }

    output
}

/// Mix multi-channel interleaved samples down to mono by averaging channels.
/// Accepts u32 channel count (used by system_audio's ASBD).
pub fn mix_to_mono(samples: &[i16], channels: u32) -> Vec<i16> {
    if channels <= 1 {
        return samples.to_vec();
    }
    let ch = channels as usize;
    samples
        .chunks_exact(ch)
        .map(|frame| {
            let sum: i32 = frame.iter().map(|&s| s as i32).sum();
            (sum / ch as i32) as i16
        })
        .collect()
}
