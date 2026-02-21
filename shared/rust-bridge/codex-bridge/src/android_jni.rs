use jni::objects::JClass;
use jni::sys::jint;
use jni::JNIEnv;

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_litter_android_core_bridge_NativeCodexBridge_nativeStartServerPort(
    _env: JNIEnv,
    _class: JClass,
) -> jint {
    let mut port: u16 = 0;
    let status = crate::codex_start_server(&mut port as *mut u16);
    if status == 0 {
        port as jint
    } else {
        status as jint
    }
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_com_litter_android_core_bridge_NativeCodexBridge_nativeStopServer(
    _env: JNIEnv,
    _class: JClass,
) {
    crate::codex_stop_server();
}
