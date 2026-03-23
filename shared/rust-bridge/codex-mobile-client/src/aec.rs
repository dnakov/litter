use std::ffi::c_void;
use std::slice;

use sonora::config::{EchoCanceller, HighPassFilter};
use sonora::{AudioProcessing, Config, StreamConfig};

struct AecState {
    processor: AudioProcessing,
    frame_size: usize,
    /// Scratch buffer reused across calls to avoid per-frame allocation.
    scratch: Vec<f32>,
}

#[unsafe(no_mangle)]
pub extern "C" fn aec_create(sample_rate: u32) -> *mut c_void {
    let config = Config {
        echo_canceller: Some(EchoCanceller::default()),
        high_pass_filter: Some(HighPassFilter::default()),
        ..Default::default()
    };

    let stream = StreamConfig::new(sample_rate, 1);
    let processor = AudioProcessing::builder()
        .config(config)
        .capture_config(stream)
        .render_config(stream)
        .build();

    let frame_size = stream.num_frames() as usize;
    let state = Box::new(AecState {
        processor,
        frame_size,
        scratch: vec![0.0; frame_size],
    });
    Box::into_raw(state) as *mut c_void
}

#[unsafe(no_mangle)]
pub extern "C" fn aec_destroy(handle: *mut c_void) {
    if handle.is_null() {
        return;
    }

    unsafe {
        drop(Box::from_raw(handle as *mut AecState));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn aec_get_frame_size(handle: *const c_void) -> usize {
    if handle.is_null() {
        return 0;
    }

    let state = unsafe { &*(handle as *const AecState) };
    state.frame_size
}

#[unsafe(no_mangle)]
pub extern "C" fn aec_analyze_render(
    handle: *mut c_void,
    samples: *const f32,
    count: usize,
) -> i32 {
    if handle.is_null() || samples.is_null() {
        return -5;
    }

    let state = unsafe { &mut *(handle as *mut AecState) };
    if state.frame_size == 0 || count % state.frame_size != 0 {
        return -8;
    }

    let data = unsafe { slice::from_raw_parts(samples, count) };
    for chunk in data.chunks_exact(state.frame_size) {
        let dest = &mut state.scratch[..state.frame_size];
        if let Err(error) = state.processor.process_render_f32(&[chunk], &mut [dest]) {
            eprintln!("[aec] analyze_render failed: {error}");
            return -1;
        }
    }

    0
}

#[unsafe(no_mangle)]
pub extern "C" fn aec_process_capture(handle: *mut c_void, samples: *mut f32, count: usize) -> i32 {
    if handle.is_null() || samples.is_null() {
        return -5;
    }

    let state = unsafe { &mut *(handle as *mut AecState) };
    if state.frame_size == 0 || count % state.frame_size != 0 {
        return -8;
    }

    let data = unsafe { slice::from_raw_parts_mut(samples, count) };
    for chunk in data.chunks_exact_mut(state.frame_size) {
        let src: Vec<f32> = chunk.to_vec();
        if let Err(error) = state.processor.process_capture_f32(&[&src], &mut [chunk]) {
            eprintln!("[aec] process_capture failed: {error}");
            return -1;
        }
    }

    0
}
