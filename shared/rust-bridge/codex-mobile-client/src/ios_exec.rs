use std::collections::HashMap;
use std::ffi::CString;
use std::ffi::c_char;
use std::ffi::c_int;
use std::ffi::c_void;
use std::path::Path;
use std::sync::OnceLock;

use crate::mobile_exec_command::mobile_system_command;

// Defined in apps/ios/Sources/Litter/Bridge/IosSystemBridge.m and linked by Xcode.
unsafe extern "C" {
    fn codex_ios_system_run(
        cmd: *const c_char,
        cwd: *const c_char,
        output: *mut *mut c_char,
        output_len: *mut usize,
    ) -> c_int;
    fn free(ptr: *mut c_void);
}

static IOS_EXEC_HOOK_INSTALLED: OnceLock<()> = OnceLock::new();

pub(crate) fn install() {
    IOS_EXEC_HOOK_INSTALLED.get_or_init(|| {
        codex_core::exec::set_ios_exec_hook(run_command);
        crate::shell_preflight::install();
    });
}

pub(crate) fn run_command(
    argv: &[String],
    cwd: &Path,
    _env: &HashMap<String, String>,
) -> (i32, Vec<u8>) {
    // Run apply_patch in-process since ios_system cannot exec the app binary.
    if argv
        .iter()
        .any(|arg| arg == codex_apply_patch::CODEX_CORE_APPLY_PATCH_ARG1)
    {
        let patch_arg = argv
            .iter()
            .skip_while(|arg| *arg != codex_apply_patch::CODEX_CORE_APPLY_PATCH_ARG1)
            .nth(1);
        if let Some(patch) = patch_arg {
            eprintln!("[ios-exec] apply_patch in-process (cwd={})", cwd.display());
            let cwd_abs = match codex_utils_absolute_path::AbsolutePathBuf::from_absolute_path(cwd)
            {
                Ok(abs) => abs,
                Err(err) => {
                    let msg = format!("invalid cwd for apply_patch: {err}\n");
                    eprintln!("[ios-exec] apply_patch setup error: {err}");
                    return (1, msg.into_bytes());
                }
            };
            let mut stdout_buf = Vec::new();
            let mut stderr_buf = Vec::new();
            let fs = codex_exec_server::LOCAL_FS.clone();
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(rt) => rt,
                Err(err) => {
                    let msg = format!("build tokio runtime for apply_patch: {err}\n");
                    eprintln!("[ios-exec] apply_patch runtime error: {err}");
                    return (1, msg.into_bytes());
                }
            };
            let result = runtime.block_on(codex_apply_patch::apply_patch(
                patch,
                &cwd_abs,
                &mut stdout_buf,
                &mut stderr_buf,
                fs.as_ref(),
                None,
            ));
            let code = match result {
                Ok(()) => 0,
                Err(err) => {
                    eprintln!("[ios-exec] apply_patch error: {err}");
                    if stderr_buf.is_empty() {
                        stderr_buf = format!("{err}\n").into_bytes();
                    }
                    1
                }
            };
            let mut output = stdout_buf;
            output.extend_from_slice(&stderr_buf);
            eprintln!(
                "[ios-exec] apply_patch exit={code} output_len={}",
                output.len()
            );
            return (code, output);
        }
    }

    let cmd = mobile_system_command(argv);
    eprintln!("[ios-exec] run: {cmd} (cwd={})", cwd.display());

    let Ok(cmd_cstr) = CString::new(cmd.clone()) else {
        eprintln!("[ios-exec] invalid command string");
        return (-1, b"invalid command string\n".to_vec());
    };
    let Ok(cwd_cstr) = CString::new(cwd.to_string_lossy().as_ref()) else {
        eprintln!("[ios-exec] invalid cwd string");
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
        let buffer = slice.to_vec();
        unsafe { free(output_ptr as *mut c_void) };
        buffer
    } else {
        Vec::new()
    };

    let preview = String::from_utf8_lossy(&output);
    let preview = if preview.len() > 200 {
        &preview[..200]
    } else {
        &preview
    };
    eprintln!("[ios-exec] exit={code} output_len={output_len} preview={preview}");

    (code, output)
}
