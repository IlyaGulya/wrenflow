use std::{env, path::PathBuf, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=native/PlatformBridge.swift");

    let out_dir = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR is set by Cargo"));
    let object = out_dir.join("PlatformBridge.o");
    let architecture = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        Ok(other) => panic!("unsupported macOS architecture: {other}"),
        Err(error) => panic!("CARGO_CFG_TARGET_ARCH is required: {error}"),
    };
    let deployment_target = env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "10.15".into());
    let target = format!("{architecture}-apple-macosx{deployment_target}");
    let status = Command::new("xcrun")
        .args([
            "swiftc",
            "-parse-as-library",
            "-O",
            "-whole-module-optimization",
            "-target",
        ])
        .arg(&target)
        .args(["-emit-object", "native/PlatformBridge.swift", "-o"])
        .arg(&object)
        .status()
        .expect("xcrun swiftc must be available");

    assert!(status.success(), "Swift platform bridge failed to compile");

    let swiftc = Command::new("xcrun")
        .args(["--find", "swiftc"])
        .output()
        .expect("xcrun must locate swiftc");
    assert!(swiftc.status.success(), "xcrun could not locate swiftc");
    let swiftc = PathBuf::from(String::from_utf8_lossy(&swiftc.stdout).trim());
    let swift_runtime = swiftc
        .parent()
        .and_then(|bin| bin.parent())
        .expect("swiftc must be under a toolchain usr/bin")
        .join("lib/swift/macosx");

    println!("cargo:rustc-link-arg={}", object.display());
    println!("cargo:rustc-link-search=native={}", swift_runtime.display());
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-lib=framework=ApplicationServices");
    println!("cargo:rustc-link-lib=framework=AVFoundation");
    println!("cargo:rustc-link-lib=framework=Foundation");
}
