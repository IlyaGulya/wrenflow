fn main() {
    println!("cargo:rerun-if-changed=src/os_log_shim.c");

    if std::env::var("CARGO_CFG_TARGET_VENDOR").as_deref() == Ok("apple") {
        let mut build = cc::Build::new();
        build.file("src/os_log_shim.c").warnings(true);
        // Homebrew binutils `ar` emits a GNU symbol-table member that Apple's
        // linker rejects. The platform archive tool is part of the macOS SDK
        // contract already required by the signed app build.
        if std::path::Path::new("/usr/bin/ar").exists() {
            build.archiver("/usr/bin/ar");
        }
        build.compile("wrenflow_os_log_shim");
    }
}
