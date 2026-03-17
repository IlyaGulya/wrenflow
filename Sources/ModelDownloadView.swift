import SwiftUI

struct ModelDownloadView: View {
    @ObservedObject var localTranscriptionService: LocalTranscriptionService
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                // Icon
                Group {
                    switch localTranscriptionService.state {
                    case .ready:
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.green)
                    case .error:
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.red)
                    default:
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 40, height: 40)
                    }
                }

                // Title + description
                switch localTranscriptionService.state {
                case .notLoaded:
                    stateContent(
                        title: "Preparing Download",
                        subtitle: "Setting up the speech recognition model."
                    )

                case .downloading(let progress):
                    VStack(spacing: 8) {
                        Text("Downloading Model")
                            .font(.system(size: 14, weight: .semibold))

                        // Progress bar
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.accentColor)

                        HStack {
                            Text("Parakeet TDT 0.6B (int8)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Text("~640 MB · This only happens once.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                case .compiling:
                    stateContent(
                        title: "Loading Model",
                        subtitle: "Optimizing for your device. This takes a moment."
                    )

                case .ready:
                    stateContent(
                        title: "Ready",
                        subtitle: "The speech recognition model is loaded."
                    )

                case .error(let message):
                    VStack(spacing: 6) {
                        Text("Download Failed")
                            .font(.system(size: 14, weight: .semibold))
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Footer buttons
            HStack {
                if case .error = localTranscriptionService.state {
                    Button("Retry") {
                        localTranscriptionService.initialize()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Spacer()
                Button(buttonLabel) {
                    onDismiss()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var buttonLabel: String {
        switch localTranscriptionService.state {
        case .ready: return "Done"
        case .error: return "Close"
        default: return "Hide"
        }
    }

    private func stateContent(title: String, subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
