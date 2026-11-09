import SwiftUI

struct MacAIAnalysisSettingsSection: View {
    @AppStorage(AIAudioSettings.enabledKey) private var enabled = false
    @ObservedObject private var installer = AIModelInstaller.shared

    var body: some View {
        Section {
            Toggle("On-Device AI Analysis", isOn: $enabled)
                .onChange(of: enabled) { _, on in
                    if on { installer.installIfNeeded() } else { installer.cancel() }
                }
            if enabled {
                switch installer.state {
                case .downloading(let fraction):
                    ProgressView(value: fraction) {
                        Text("Downloading Models")
                    }
                    Button("Cancel", role: .cancel) { installer.cancel() }
                case .failed(let message):
                    LabeledContent("Models", value: message)
                    Button("Try Again") { installer.installIfNeeded() }
                case .idle:
                    if installer.isInstalled {
                        LabeledContent("Models", value: Self.size(installer.installedBytes))
                    } else {
                        Button("Download Models") { installer.installIfNeeded() }
                    }
                }
            }
            if installer.installedBytes > 0, installer.state == .idle {
                Button("Delete Models", role: .destructive) {
                    enabled = false
                    installer.delete()
                }
            }
        } header: {
            Text("Analysis")
        } footer: {
            Text("Finds beats, bars, vocals, drum loops and bass with models that run on this Mac. The first download is \(Self.size(AIModelStore.totalBytes)).")
        }
        .task {
            if enabled { installer.installIfNeeded() }
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
