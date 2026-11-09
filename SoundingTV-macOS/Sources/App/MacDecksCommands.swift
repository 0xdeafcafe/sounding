import SwiftUI

struct DecksCommands: Commands {
    private var isAutoMixEnabled: Bool {
        PlayerService.shared.djDirector.snapshot?.isAutoMixEnabled ?? PlayerService.shared.isAutoMixEnabled
    }

    var body: some Commands {
        CommandMenu("Decks") {
            if isAutoMixEnabled {
                Button {
                    PlayerService.shared.endDJSession()
                } label: {
                    Label("Turn Off Auto Mix", systemImage: "wand.and.stars.inverse")
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            } else {
                Button {
                    MacNowPlayingPresentation.shared.showsAutoMixSetup = true
                } label: {
                    Label("Start Auto Mix…", systemImage: "wand.and.stars")
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }

            Divider()

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
