use std::{env, path::PathBuf, process::Command};

fn main() {
    const SWIFT_SOURCES: &[&str] = &[
        "macos/WrenflowAccessibilityBridge.swift",
        "macos/WrenflowHotkeyMonitor.swift",
        "macos/WrenflowOverlayController.swift",
        "macos/WrenflowShell.swift",
    ];
    for source in SWIFT_SOURCES {
        println!("cargo:rerun-if-changed={source}");
    }

    let out_dir = match env::var_os("OUT_DIR") {
        Some(out_dir) => PathBuf::from(out_dir),
        None => panic!("Cargo must set OUT_DIR"),
    };
    let dylib = out_dir.join("libWrenflowShell.dylib");
    let architecture = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        Ok(other) => panic!("unsupported macOS architecture: {other}"),
        Err(error) => panic!("CARGO_CFG_TARGET_ARCH is required: {error}"),
    };
    let deployment_target = env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "14.0".into());
    let target = format!("{architecture}-apple-macosx{deployment_target}");

    let mut swiftc = Command::new("xcrun");
    swiftc.args([
        "swiftc",
        "-parse-as-library",
        "-O",
        "-whole-module-optimization",
        "-module-name",
        "WrenflowShell",
        "-target",
    ]);
    swiftc.arg(&target);
    swiftc.args([
        "-emit-library",
        "-Xlinker",
        "-install_name",
        "-Xlinker",
        "@rpath/libWrenflowShell.dylib",
    ]);
    swiftc.args(SWIFT_SOURCES);
    swiftc.arg("-o").arg(&dylib);
    let status = match swiftc.status() {
        Ok(status) => status,
        Err(error) => panic!("xcrun swiftc must be available: {error}"),
    };
    assert!(status.success(), "Swift/AppKit shell failed to compile");

    println!("cargo:rustc-link-search=native={}", out_dir.display());
    println!("cargo:rustc-link-lib=dylib=WrenflowShell");
    println!("cargo:rustc-link-arg=-Wl,-rpath,@executable_path/../Frameworks");
}
