use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::SampleFormat;

use super::wav_writer::WavWriter;

/// Resamples audio from `from_rate` to `to_rate` using linear interpolation.
fn resample(samples: &[i16], from_rate: u32, to_rate: u32) -> Vec<i16> {
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
fn mix_to_mono(samples: &[i16], channels: u16) -> Vec<i16> {
    if channels == 1 {
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

/// Calculate RMS audio level normalized to 0.0-1.0.
fn calculate_rms_level(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum_sq: f64 = samples.iter().map(|&s| (s as f64) * (s as f64)).sum();
    let rms = (sum_sq / samples.len() as f64).sqrt();
    (rms / 32767.0).min(1.0) as f32
}

/// Convert any cpal sample format buffer to i16 samples.
fn samples_to_i16(data: &[u8], format: SampleFormat) -> Vec<i16> {
    match format {
        SampleFormat::I16 => data
            .chunks_exact(2)
            .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]))
            .collect(),
        SampleFormat::F32 => data
            .chunks_exact(4)
            .map(|chunk| {
                let f = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                (f.clamp(-1.0, 1.0) * 32767.0) as i16
            })
            .collect(),
        SampleFormat::U16 => data
            .chunks_exact(2)
            .map(|chunk| {
                let u = u16::from_le_bytes([chunk[0], chunk[1]]);
                (u as i32 - 32768) as i16
            })
            .collect(),
        _ => {
            log::warn!(
                "Unsupported sample format {:?}, attempting f32 interpretation",
                format
            );
            data.chunks_exact(4)
                .map(|chunk| {
                    let f = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
                    (f.clamp(-1.0, 1.0) * 32767.0) as i16
                })
                .collect()
        }
    }
}

/// MicRecorder manages microphone recording on a dedicated thread.
/// The cpal `Stream` is !Send+!Sync, so it must live on the thread that created it.
pub struct MicRecorder {
    is_recording: Arc<AtomicBool>,
    wav_path: Mutex<Option<PathBuf>>,
    writer: Arc<Mutex<Option<WavWriter>>>,
    /// Signal the recording thread to stop
    stop_signal: Arc<AtomicBool>,
    /// Handle to the recording thread
    thread_handle: Mutex<Option<std::thread::JoinHandle<()>>>,
}

// Safety: MicRecorder is Send+Sync because we don't store the cpal::Stream directly.
// The Stream lives only on the dedicated recording thread.
unsafe impl Send for MicRecorder {}
unsafe impl Sync for MicRecorder {}

impl MicRecorder {
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            is_recording: Arc::new(AtomicBool::new(false)),
            wav_path: Mutex::new(None),
            writer: Arc::new(Mutex::new(None)),
            stop_signal: Arc::new(AtomicBool::new(false)),
            thread_handle: Mutex::new(None),
        })
    }

    /// Start recording from the default input device.
    /// The cpal stream is created and managed on a dedicated thread.
    pub fn start(
        &mut self,
        path: PathBuf,
        level_callback: impl Fn(f32) + Send + 'static,
    ) -> Result<(), String> {
        if self.is_recording.load(Ordering::SeqCst) {
            return Err("Already recording".to_string());
        }

        let wav = WavWriter::new(&path)?;
        *self.writer.lock().map_err(|e| e.to_string())? = Some(wav);
        *self.wav_path.lock().map_err(|e| e.to_string())? = Some(path);

        self.is_recording.store(true, Ordering::SeqCst);
        self.stop_signal.store(false, Ordering::SeqCst);

        let writer = self.writer.clone();
        let stop_signal = self.stop_signal.clone();
        let is_recording = self.is_recording.clone();

        let handle = std::thread::spawn(move || {
            if let Err(e) = run_recording_thread(writer, stop_signal.clone(), level_callback) {
                log::error!("Recording thread error: {}", e);
                is_recording.store(false, Ordering::SeqCst);
            }
        });

        *self.thread_handle.lock().map_err(|e| e.to_string())? = Some(handle);

        log::info!("Microphone recording started");
        Ok(())
    }

    /// Stop recording and return the WAV file path.
    pub fn stop(&mut self) -> Result<PathBuf, String> {
        if !self.is_recording.load(Ordering::SeqCst) {
            return Err("Not recording".to_string());
        }

        // Signal the recording thread to stop
        self.stop_signal.store(true, Ordering::SeqCst);
        self.is_recording.store(false, Ordering::SeqCst);

        // Wait for the thread to finish
        if let Some(handle) = self.thread_handle.lock().map_err(|e| e.to_string())?.take() {
            let _ = handle.join();
        }

        // Finalize the WAV file
        let writer = self
            .writer
            .lock()
            .map_err(|e| e.to_string())?
            .take()
            .ok_or_else(|| "No active WAV writer".to_string())?;

        writer.finalize()?;

        let path = self
            .wav_path
            .lock()
            .map_err(|e| e.to_string())?
            .take()
            .ok_or_else(|| "No WAV path set".to_string())?;

        log::info!("Microphone recording stopped: {:?}", path);
        Ok(path)
    }
}

/// Runs the audio capture on the current thread (blocking until stop_signal is set).
fn run_recording_thread(
    writer: Arc<Mutex<Option<WavWriter>>>,
    stop_signal: Arc<AtomicBool>,
    level_callback: impl Fn(f32) + Send + 'static,
) -> Result<(), String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or_else(|| "No input device available".to_string())?;

    log::info!("Using input device: {}", device.name().unwrap_or_default());

    let config = device
        .default_input_config()
        .map_err(|e| format!("Failed to get default input config: {e}"))?;

    let device_sample_rate = config.sample_rate().0;
    let device_channels = config.channels();
    let sample_format = config.sample_format();

    log::info!(
        "Device config: {}Hz, {} channels, {:?}",
        device_sample_rate,
        device_channels,
        sample_format
    );

    let target_rate = 16000u32;
    let recording_flag = stop_signal.clone();

    let stream = device
        .build_input_stream_raw(
            &config.into(),
            sample_format,
            move |data: &cpal::Data, _: &cpal::InputCallbackInfo| {
                if recording_flag.load(Ordering::SeqCst) {
                    return;
                }

                let raw_bytes = data.bytes();
                let i16_samples = samples_to_i16(raw_bytes, sample_format);

                // Mix to mono
                let mono = mix_to_mono(&i16_samples, device_channels);

                // Calculate level before resampling (more responsive)
                let level = calculate_rms_level(&mono);
                level_callback(level);

                // Resample to target rate
                let resampled = resample(&mono, device_sample_rate, target_rate);

                // Write to WAV
                if let Ok(mut guard) = writer.lock() {
                    if let Some(ref mut w) = *guard {
                        if let Err(e) = w.write_samples(&resampled) {
                            log::error!("Failed to write audio samples: {}", e);
                        }
                    }
                }
            },
            |err: cpal::StreamError| {
                log::error!("Audio stream error: {}", err);
            },
            None,
        )
        .map_err(|e| format!("Failed to build input stream: {e}"))?;

    stream
        .play()
        .map_err(|e| format!("Failed to start audio stream: {e}"))?;

    // Block this thread until stop is signaled
    while !stop_signal.load(Ordering::SeqCst) {
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    // Stream is dropped here, stopping capture
    drop(stream);

    Ok(())
}
