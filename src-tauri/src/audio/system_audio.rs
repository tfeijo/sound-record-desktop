use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use super::wav_writer::WavWriter;

/// SystemRecorder captures system audio (what other meeting participants say).
///
/// TODO: Implement real ScreenCaptureKit capture via `objc2` bindings.
/// The key macOS APIs needed are:
///   1. `SCShareableContent::get_shareable_content()` — enumerate available content
///   2. `SCContentFilter` — filter to capture system audio only (excludeCurrentProcess)
///   3. `SCStreamConfiguration` — configure for 16kHz mono audio capture
///   4. `SCStream` — the actual capture stream with `SCStreamOutput` delegate
///
/// For now this is a stub that creates a valid (silent) WAV file so the rest of
/// the pipeline (dual-file recording, start/stop orchestration) works end-to-end.
pub struct SystemRecorder {
    is_recording: Arc<AtomicBool>,
    wav_path: Mutex<Option<PathBuf>>,
    writer: Arc<Mutex<Option<WavWriter>>>,
    stop_signal: Arc<AtomicBool>,
    thread_handle: Mutex<Option<std::thread::JoinHandle<()>>>,
}

// Safety: same reasoning as MicRecorder — no !Send types stored directly.
unsafe impl Send for SystemRecorder {}
unsafe impl Sync for SystemRecorder {}

impl SystemRecorder {
    pub fn new() -> Result<Self, String> {
        Ok(Self {
            is_recording: Arc::new(AtomicBool::new(false)),
            wav_path: Mutex::new(None),
            writer: Arc::new(Mutex::new(None)),
            stop_signal: Arc::new(AtomicBool::new(false)),
            thread_handle: Mutex::new(None),
        })
    }

    /// Start capturing system audio to `path`.
    ///
    /// Currently writes silence at 16kHz as a placeholder. The `level_callback`
    /// is invoked periodically with 0.0 to keep the UI responsive.
    pub fn start(
        &mut self,
        path: PathBuf,
        level_callback: impl Fn(f32) + Send + 'static,
    ) -> Result<(), String> {
        if self.is_recording.load(Ordering::SeqCst) {
            return Err("System recorder already recording".to_string());
        }

        log::warn!(
            "System audio capture not yet implemented (ScreenCaptureKit stub). \
             Recording silence to {:?}",
            path
        );

        let wav = WavWriter::new(&path)?;
        *self.writer.lock().map_err(|e| e.to_string())? = Some(wav);
        *self.wav_path.lock().map_err(|e| e.to_string())? = Some(path);

        self.is_recording.store(true, Ordering::SeqCst);
        self.stop_signal.store(false, Ordering::SeqCst);

        let writer = self.writer.clone();
        let stop_signal = self.stop_signal.clone();
        let is_recording = self.is_recording.clone();

        let handle = std::thread::spawn(move || {
            // Write periodic silence so the WAV file has a plausible duration that
            // roughly matches the mic recording. 16kHz * 50ms = 800 samples per tick.
            let silence = vec![0i16; 800];

            while !stop_signal.load(Ordering::SeqCst) {
                // Report zero level
                level_callback(0.0);

                if let Ok(mut guard) = writer.lock() {
                    if let Some(ref mut w) = *guard {
                        if let Err(e) = w.write_samples(&silence) {
                            log::error!("System audio stub: failed to write silence: {}", e);
                            break;
                        }
                    }
                }

                std::thread::sleep(std::time::Duration::from_millis(50));
            }

            is_recording.store(false, Ordering::SeqCst);
        });

        *self.thread_handle.lock().map_err(|e| e.to_string())? = Some(handle);

        log::info!("System audio recording started (stub/silence)");
        Ok(())
    }

    /// Stop recording and return the WAV file path.
    pub fn stop(&mut self) -> Result<PathBuf, String> {
        if !self.is_recording.load(Ordering::SeqCst) {
            // The thread may have already cleared the flag; check if we have a path
            if self.wav_path.lock().map_err(|e| e.to_string())?.is_none() {
                return Err("System recorder not recording".to_string());
            }
        }

        self.stop_signal.store(true, Ordering::SeqCst);
        self.is_recording.store(false, Ordering::SeqCst);

        if let Some(handle) = self.thread_handle.lock().map_err(|e| e.to_string())?.take() {
            let _ = handle.join();
        }

        let writer = self
            .writer
            .lock()
            .map_err(|e| e.to_string())?
            .take()
            .ok_or_else(|| "No active system WAV writer".to_string())?;

        writer.finalize()?;

        let path = self
            .wav_path
            .lock()
            .map_err(|e| e.to_string())?
            .take()
            .ok_or_else(|| "No system WAV path set".to_string())?;

        log::info!("System audio recording stopped: {:?}", path);
        Ok(path)
    }
}
