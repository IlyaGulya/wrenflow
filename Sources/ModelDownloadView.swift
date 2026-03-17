import SwiftUI

struct ModelDownloadView: View {
    @ObservedObject var localTranscriptionService: LocalTranscriptionService
    var onDismiss: () -> Void

    @State private var birdOffset: CGFloat = 0
    @State private var wavePhase: Double = 0

    var body: some View {
        ZStack {
            // White background
            Color.white.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 36)

                // Bird icon
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .opacity(0.6)
                    .offset(y: birdOffset)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                            birdOffset = -4
                        }
                    }

                Spacer().frame(height: 20)

                // Content per state
                Group {
                    switch localTranscriptionService.state {
                    case .notLoaded:
                        downloadContent(progress: 0, status: "Preparing...")

                    case .downloading(let progress):
                        downloadContent(progress: progress, status: downloadStatus(progress))

                    case .compiling:
                        VStack(spacing: 10) {
                            Text("Loading model")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.black)

                            // Animated wave bars
                            HStack(spacing: 3) {
                                ForEach(0..<5, id: \.self) { i in
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(Color.black.opacity(0.2))
                                        .frame(width: 3, height: barHeight(index: i))
                                        .animation(
                                            .easeInOut(duration: 0.5)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(i) * 0.1),
                                            value: wavePhase
                                        )
                                }
                            }
                            .frame(height: 20)
                            .onAppear { wavePhase = 1 }

                            Text("Optimizing for your device")
                                .font(.system(size: 12))
                                .foregroundColor(Color.black.opacity(0.35))
                        }

                    case .ready:
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(Color(red: 0.2, green: 0.7, blue: 0.4))

                            Text("Ready")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.black)
                        }

                    case .error(let message):
                        VStack(spacing: 10) {
                            Text("Download failed")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.black)

                            Text(message)
                                .font(.system(size: 11))
                                .foregroundColor(Color.black.opacity(0.4))
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .padding(.horizontal, 20)

                            Button(action: { localTranscriptionService.initialize() }) {
                                Text("Retry")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.black.opacity(0.15), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()

                // Footer
                if !isDownloading {
                    Button(action: onDismiss) {
                        Text(footerLabel)
                            .font(.system(size: 12))
                            .foregroundColor(Color.black.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 16)
                } else {
                    Spacer().frame(height: 16)
                }
            }
        }
        .frame(width: 300, height: 260)
        .environment(\.colorScheme, .light)
    }

    // MARK: - Download content

    private func downloadContent(progress: Double, status: String) -> some View {
        VStack(spacing: 14) {
            Text("Downloading model")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.black)

            // Thin progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.06))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.5))
                        .frame(width: max(4, geo.size.width * CGFloat(progress)), height: 4)
                        .animation(.easeInOut(duration: 0.3), value: progress)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 32)

            // Status text
            Text(status)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color.black.opacity(0.35))

            Text("Parakeet TDT · ~640 MB")
                .font(.system(size: 10))
                .foregroundColor(Color.black.opacity(0.2))
        }
    }

    // MARK: - Helpers

    private func downloadStatus(_ progress: Double) -> String {
        let pct = Int(progress * 100)
        let mbDone = Int(Double(640) * progress)
        return "\(mbDone) / 640 MB  ·  \(pct)%"
    }

    private func barHeight(index: Int) -> CGFloat {
        let base: CGFloat = wavePhase == 0 ? 6 : 6
        let heights: [CGFloat] = [12, 18, 14, 18, 12]
        return wavePhase == 0 ? base : heights[index]
    }

    private var isDownloading: Bool {
        switch localTranscriptionService.state {
        case .notLoaded, .downloading, .compiling: return true
        default: return false
        }
    }

    private var footerLabel: String {
        switch localTranscriptionService.state {
        case .ready: return "Done"
        case .error: return "Close"
        default: return "Hide"
        }
    }
}
