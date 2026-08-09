pub(crate) mod paste;
pub(crate) mod runtime_probe;

pub(crate) const fn paste_injection_supported() -> bool {
    cfg!(target_os = "macos") || cfg!(target_os = "windows") || cfg!(target_os = "linux")
}
