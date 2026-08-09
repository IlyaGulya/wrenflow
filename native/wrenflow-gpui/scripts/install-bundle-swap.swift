import Darwin
import Foundation

private let allowedTargets = [
    "/Applications/Wrenflow.app",
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications/Wrenflow.app").path,
]

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: install-bundle-swap.swift STAGED_APP TARGET_APP\n", stderr)
    exit(64)
}

let staged = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let target = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
guard allowedTargets.contains(target.path) else {
    fputs("Refusing unexpected swap target: \(target.path)\n", stderr)
    exit(65)
}
guard staged.lastPathComponent == "Wrenflow.app",
      staged.deletingLastPathComponent().lastPathComponent.hasPrefix(".Wrenflow-install.") else {
    fputs("Refusing unexpected staged bundle: \(staged.path)\n", stderr)
    exit(65)
}

let result = staged.path.withCString { stagedPath in
    target.path.withCString { targetPath in
        renameatx_np(AT_FDCWD, stagedPath, AT_FDCWD, targetPath, UInt32(RENAME_SWAP))
    }
}
guard result == 0 else {
    let message = String(cString: strerror(errno))
    fputs("Atomic bundle exchange failed: \(message)\n", stderr)
    exit(66)
}
