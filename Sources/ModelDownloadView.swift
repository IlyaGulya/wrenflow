import SwiftUI

struct ModelDownloadView: View {
    @ObservedObject var localTranscriptionService: LocalTranscriptionService
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            switch localTranscriptionService.state {
            case .notLoaded, .loading:
                ProgressView()
                    .controlSize(.large)
                Text("Setting Up Local Transcription")
                    .font(.headline)
                Text("Downloading the speech recognition model. This only happens once.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.green)
                Text("Model Ready")
                    .font(.headline)

            case .error(let message):
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.red)
                Text("Download Failed")
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    localTranscriptionService.initialize()
                }
                .buttonStyle(.borderedProminent)
            }

            Spacer()

            Button("Dismiss") {
                onDismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding(30)
        .frame(width: 360, height: 260)
    }
}
