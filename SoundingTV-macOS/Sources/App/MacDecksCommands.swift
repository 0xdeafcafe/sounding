import SwiftUI

struct DecksCommands: Commands {
    var body: some Commands {
        CommandMenu("Decks") {
            Button {
                MacConsoleController.shared.loadTarget = .a
            } label: {
                Label("Load Track to Deck A…", systemImage: "a.square")
            }
            Button {
                MacConsoleController.shared.loadTarget = .b
            } label: {
                Label("Load Track to Deck B…", systemImage: "b.square")
            }

            Divider()

            Button {
                let controller = MacConsoleController.shared
                controller.focusedDeck = controller.focusedDeck.other
            } label: {
                Label("Switch Focused Deck", systemImage: "arrow.left.arrow.right")
            }

            Divider()

            Button {
                let controller = MacConsoleController.shared
                let deck = controller.focusedDeck
                controller.setKeyLocked(deck, !(controller.keyLocked[deck.rawValue] ?? true))
            } label: {
                Label("Toggle Key Lock", systemImage: "key")
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button {
                let controller = MacConsoleController.shared
                controller.resetTempo(controller.focusedDeck)
            } label: {
                Label("Reset Tempo to 0%", systemImage: "metronome")
            }
            .keyboardShortcut("t", modifiers: [.command])

            Divider()

            Button {
                MacConsoleController.shared.showKeyboardShortcuts = true
            } label: {
                Label("Keyboard Shortcuts…", systemImage: "keyboard")
            }
        }
    }
}
