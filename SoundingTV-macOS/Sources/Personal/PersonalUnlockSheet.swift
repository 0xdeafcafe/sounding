#if SOUNDING_PERSONAL
import AppKit
import SwiftUI

extension View {
    func personalUnlockTrigger() -> some View {
        modifier(PersonalUnlockTrigger())
    }
}

private struct PersonalUnlockTrigger: ViewModifier {
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.option) { presented = true }
            }
            .sheet(isPresented: $presented) {
                PersonalUnlockSheet()
            }
    }
}

struct PersonalUnlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var unlocked = PersonalCodeLock.live().isUnlocked
    @State private var rejected = false
    @State private var cooling = false

    private let lock = PersonalCodeLock.live()

    var body: some View {
        Group {
            if !lock.isConfigured {
                ContentUnavailableView("No Code Set", systemImage: "lock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if unlocked {
                        Section {
                            LabeledContent("SoundCloud Audio on USB", value: "On")
                        } footer: {
                            Text("Export to USB includes tracks without a local file.")
                        }
                    } else {
                        Section {
                            SecureField("Code", text: $code)
                                .onSubmit(attemptUnlock)
                        } footer: {
                            if rejected { Text("That code isn’t right.") }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 400, height: 180)
        .toolbar {
            if unlocked {
                ToolbarItem(placement: .destructiveAction) {
                    Button("Turn Off", role: .destructive) {
                        lock.lock()
                        unlocked = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unlock", action: attemptUnlock)
                        .disabled(code.isEmpty || cooling || !lock.isConfigured)
                }
            }
        }
    }

    private func attemptUnlock() {
        guard !code.isEmpty, !cooling else { return }
        if lock.unlock(with: code) {
            code = ""
            rejected = false
            unlocked = true
            return
        }
        code = ""
        rejected = true
        cooling = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            cooling = false
        }
    }
}
#endif
