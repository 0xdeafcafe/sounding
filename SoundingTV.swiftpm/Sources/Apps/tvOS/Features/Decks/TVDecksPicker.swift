import SwiftUI

struct TVDecksPicker: View {
    let model: DecksLiveModel
    let onClose: () -> Void

    @State private var picks = DeckNextPicksModel()
    @FocusState private var focused: String?

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            panel
        }
        .padding(.vertical, 48)
        .padding(.trailing, 64)
        .background {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .onExitCommand(perform: onClose)
        .task { await picks.load() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(model.hasTrack ? "Play Next" : "Choose a Track")
                    .font(.tvTitle)
                    .foregroundStyle(Color.scTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let title = model.onAir.track?.title {
                    Text("Ranked by how well each mixes with \(title).")
                        .font(.tvCallout)
                        .foregroundStyle(Color.scTextSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, Space.section)
            content
        }
        .padding(.top, Space.section)
        .frame(width: 880)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
        .liquidGlass(in: RoundedRectangle(cornerRadius: 48, style: .continuous))
        .focusSection()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.hasTrack ? "Play Next" : "Choose a Track")
    }

    @ViewBuilder
    private var content: some View {
        if !picks.hasLoaded {
            LoadingPlaceholder(.platformTrackList, count: 6)
                .padding(.horizontal, Space.base)
        } else if picks.isEmpty {
            VStack(spacing: Space.base) {
                ContentUnavailableView(
                    "Nothing to Choose From",
                    systemImage: "music.note.list",
                    description: Text("Queue some tracks or like some on SoundCloud, and they show up here.")
                )
                Button("Close", action: onClose)
                    .buttonStyle(TVDecksChromeStyle())
                    .focused($focused, equals: "close")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .defaultFocus($focused, "close")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.tight) {
                    ForEach(picks.sections) { section in
                        Text(section.title)
                            .font(.tvSection)
                            .foregroundStyle(Color.scTextSecondary)
                            .padding(.horizontal, Space.base)
                            .padding(.top, Space.base)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.picks) { pick in
                            TVDecksPickRow(pick: pick, isSuggested: section.kind == .suggested) {
                                choose(pick.track)
                            }
                            .focused($focused, equals: "\(section.id).\(pick.id)")
                        }
                    }
                }
                .padding(.horizontal, Space.base)
                .padding(.bottom, Space.section)
            }
            .scrollClipDisabled()
            .defaultFocus($focused, picks.sections.first.flatMap { section in section.picks.first.map { "\(section.id).\($0.id)" } })
        }
    }

    private func choose(_ track: Track) {
        if model.hasTrack {
            model.setNext(track)
        } else {
            model.play(track)
        }
        onClose()
    }
}

private struct TVDecksPickRow: View {
    let pick: DeckPick
    let isSuggested: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RowLabel(pick: pick, isSuggested: isSuggested)
        }
        .buttonStyle(TVDecksRowStyle())
        .accessibilityLabel("\(pick.track.title), \(pick.track.user.displayName)")
        .accessibilityValue([pick.readoutText, pick.matchText].compactMap { $0 }.joined(separator: ", "))
        .accessibilityIdentifier("decks.pick.\(pick.id)")
    }

    private struct RowLabel: View {
        let pick: DeckPick
        let isSuggested: Bool

        @Environment(\.isFocused) private var isFocused

        var body: some View {
            HStack(spacing: Space.base) {
                ArtworkImage(url: pick.track.artworkURL, identity: pick.track.id)
                    .aspectRatio(1, contentMode: .fill)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(pick.track.title)
                        .font(.tvBodyEmph)
                        .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
                        .lineLimit(1)
                    Text(pick.track.user.displayName)
                        .font(.tvCaption)
                        .foregroundStyle(isFocused ? Color.scChromeFocusOn.opacity(0.7) : Color.scTextSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.snug)
                VStack(alignment: .trailing, spacing: 2) {
                    if let readout = pick.readoutText {
                        Text(readout)
                            .font(.tvCaptionEmph)
                            .monospacedDigit()
                            .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
                    }
                    if let match = pick.matchText {
                        HStack(spacing: 6) {
                            if pick.isGoodMatch {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(match)
                        }
                        .font(.tvCaption)
                        .foregroundStyle(isFocused ? Color.scChromeFocusOn.opacity(0.7) : (isSuggested ? Color.scSuccess : Color.scTextSecondary))
                    }
                }
                .lineLimit(1)
            }
            .padding(.horizontal, Space.snug)
            .frame(height: 112)
        }
    }
}

struct TVDecksRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration

        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                        .fill(isFocused ? Color.scChromeFocus : Color.clear)
                }
                .contentShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
                .scaleEffect(configuration.isPressed ? 1.01 : (isFocused ? 1.03 : 1))
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 18, y: 10)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}
