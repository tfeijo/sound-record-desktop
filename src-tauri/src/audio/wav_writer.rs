use std::path::Path;

use hound::{SampleFormat, WavSpec, WavWriter as HoundWavWriter};

/// Thin wrapper around hound's WavWriter configured for 16kHz mono 16-bit PCM.
pub struct WavWriter {
    inner: HoundWavWriter<std::io::BufWriter<std::fs::File>>,
}

impl WavWriter {
    /// Create a new WAV writer at the given path.
    /// Configured for 16000 Hz, mono, 16-bit PCM.
    pub fn new(path: &Path) -> Result<Self, String> {
        let spec = WavSpec {
            channels: 1,
            sample_rate: 16000,
            bits_per_sample: 16,
            sample_format: SampleFormat::Int,
        };

        let writer =
            HoundWavWriter::create(path, spec).map_err(|e| format!("Failed to create WAV file: {e}"))?;

        Ok(Self { inner: writer })
    }

    /// Write a slice of i16 PCM samples.
    pub fn write_samples(&mut self, samples: &[i16]) -> Result<(), String> {
        for &sample in samples {
            self.inner
                .write_sample(sample)
                .map_err(|e| format!("Failed to write sample: {e}"))?;
        }
        Ok(())
    }

    /// Finalize the WAV file (writes correct header sizes).
    pub fn finalize(self) -> Result<(), String> {
        self.inner
            .finalize()
            .map_err(|e| format!("Failed to finalize WAV: {e}"))?;
        Ok(())
    }
}
