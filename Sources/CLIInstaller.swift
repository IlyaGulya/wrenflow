import AppKit

enum CLIInstaller {
    static let installPath = "/usr/local/bin/wrenflow"

    static var isInstalled: Bool {
        guard let bundlePath = bundledCLIPath else { return false }
        guard FileManager.default.fileExists(atPath: installPath) else { return false }
        // Check if installed binary matches the bundled one
        guard let installedData = FileManager.default.contents(atPath: installPath),
              let bundledData = FileManager.default.contents(atPath: bundlePath) else {
            return false
        }
        return installedData == bundledData
    }

    static var bundledCLIPath: String? {
        Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("freeflow")
            .path
    }

    static func install() {
        guard let source = bundledCLIPath else {
            showAlert(
                title: "CLI Not Found",
                message: "The CLI binary was not found in the app bundle.",
                style: .critical
            )
            return
        }

        guard FileManager.default.fileExists(atPath: source) else {
            showAlert(
                title: "CLI Not Found",
                message: "The CLI binary was not found at \(source).",
                style: .critical
            )
            return
        }

        let dest = installPath

        // Create /usr/local/bin if needed, then copy — requires privilege escalation
        let script = """
        do shell script "mkdir -p /usr/local/bin && cp -f \(quote(source)) \(quote(dest)) && chmod +x \(quote(dest))" with administrator privileges
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                if !message.contains("User canceled") {
                    showAlert(
                        title: "Installation Failed",
                        message: message,
                        style: .critical
                    )
                }
            } else {
                showAlert(
                    title: "CLI Installed",
                    message: "The freeflow command has been installed to \(dest).\n\nUsage:\n  wrenflow start\n  freeflow stop\n  wrenflow toggle\n  freeflow status",
                    style: .informational
                )
            }
        }
    }

    private static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
