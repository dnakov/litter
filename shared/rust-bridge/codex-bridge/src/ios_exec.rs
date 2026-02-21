use std::collections::HashMap;
use std::ffi::CString;
use std::ffi::c_char;
use std::ffi::c_int;
use std::ffi::c_void;
use std::path::Path;

// Defined in Sources/CodexIOS/Bridge/IosSystemBridge.m,
// linked at Xcode build time.
unsafe extern "C" {
    fn codex_ios_system_init();
    fn codex_ios_system_run(
        cmd: *const c_char,
        cwd: *const c_char,
        output: *mut *mut c_char,
        output_len: *mut usize,
    ) -> c_int;
    fn free(ptr: *mut c_void);
}

pub fn init() {
    unsafe { codex_ios_system_init() };
}

fn shell_quote(s: &str) -> String {
    if s.contains(' ') || s.contains('\'') || s.contains('"') || s.contains('\\') {
        format!("'{}'", s.replace('\'', "'\\''"))
    } else {
        s.to_string()
    }
}

pub fn run_command(
    argv: &[String],
    cwd: &Path,
    _env: &HashMap<String, String>,
) -> (i32, Vec<u8>) {
    let quoted_args: Vec<String> = argv.iter().map(|arg| shell_quote(arg)).collect();
    let cmd = quoted_args.join(" ");
    let Ok(cmd_cstr) = CString::new(cmd) else {
        return (-1, b"invalid command string\n".to_vec());
    };
    let Ok(cwd_cstr) = CString::new(cwd.to_string_lossy().as_ref()) else {
        return (-1, b"invalid cwd string\n".to_vec());
    };

    let mut output_ptr: *mut c_char = std::ptr::null_mut();
    let mut output_len: usize = 0;

    let code = unsafe {
        codex_ios_system_run(
            cmd_cstr.as_ptr(),
            cwd_cstr.as_ptr(),
            &mut output_ptr,
            &mut output_len,
        )
    };

    let output = if !output_ptr.is_null() && output_len > 0 {
        let slice = unsafe { std::slice::from_raw_parts(output_ptr as *const u8, output_len) };
        let v = slice.to_vec();
        unsafe { free(output_ptr as *mut c_void) };
        v
    } else {
        Vec::new()
    };

    (code as i32, output)
}
