import SwiftUI

struct MacKeyboardShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private static let chassisBackground = Color(red: 0.03, green: 0.032, blue: 0.036)

    private struct Section: Identifiable {
        let group: MacConsoleView.ConsoleKeyGroup
        let bindings: [MacConsoleView.ConsoleKeyBinding]
        var id: MacConsoleView.ConsoleKeyGroup { group }
    }

    private var sections: [Section] {
        MacConsoleView.ConsoleKeyGroup.allCases.compactMap { group in
            let bindings = MacConsoleView.keyMap.filter { $0.group == group }
            return bindings.isEmpty ? nil : Section(group: group, bindings: bindings)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections, id: \.group) { section in
                        sectionView(section.group, section.bindings)
                    }
                    footnotes
                }
                .padding(18)
            }
        }
        .frame(width: 620, height: 680)
        .background(Self.chassisBackground)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DJ Console Keyboard")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                Text("Deck A uses the left side; Deck B mirrors it on the right. No ⌘ required.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 12)
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func sectionView(_ group: MacConsoleView.ConsoleKeyGroup, _ bindings: [MacConsoleView.ConsoleKeyBinding]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(group.rawValue.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
                .tracking(1.2)

            VStack(spacing: 3) {
                ForEach(bindings) { binding in
                    row(binding)
                }
            }
        }
    }

    private func row(_ binding: MacConsoleView.ConsoleKeyBinding) -> some View {
        HStack(alignment: .top, spacing: 10) {
            keyCap(binding.keyLabel)
                .frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(binding.action)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                if let note = binding.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(minWidth: 26)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
    }

    private var footnotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(Color.white.opacity(0.1))
            Text("↔ marks mirrored controls: the same finger shape does the same job on the opposite deck.")
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.38))

            Text("Shift modifies a control without changing its location: fine filter/tempo moves, coarse nudges, both-deck loop sizing, both-deck FX reset, and instant crossfader snaps.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.38))
        }
        .padding(.top, 4)
    }
}
