import SwiftUI
import AppKit

struct MacConnectionsPage: View {
    let kind: ArtistConnectionKind

    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @StateObject private var model: PeopleDirectoryModel

    init(kind: ArtistConnectionKind) {
        self.kind = kind
        _model = StateObject(wrappedValue: PeopleDirectoryModel(kind: kind))
    }

    var body: some View {
        if credentials.isSessionRejected {
            MacAccountRecoveryEmptyState(sectionName: kind.rawValue)
                .navigationTitle(kind.rawValue)
        } else if credentials.isSignedOut {
            ContentUnavailableView(
                "Sign In to See \(kind.rawValue)",
                systemImage: kind.systemImage,
                description: Text("Sign in with SoundCloud to see who you follow and who follows you.")
            )
            .macFillsPane()
            .navigationTitle(kind.rawValue)
        } else {
            PeopleDirectoryView(model: model) { people in
                MacViewportScrollView {
                    MacPeopleDirectoryGrid(people: people, model: model)
                        .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                        .padding(.top, SCContentStyle.mac.spaceBase)
                        .padding(.bottom, 32)
                }
                .defaultScrollAnchor(.top, for: .alignment)
            }
        }
    }
}

struct MacPeopleDirectoryGrid: View {
    let people: [PersonEntry]
    @ObservedObject var model: PeopleDirectoryModel

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)],
            alignment: .leading,
            spacing: 24
        ) {
            ForEach(people) { person in
                VStack(spacing: 8) {
                    NavigationLink(value: person.user) {
                        SCArtworkResolver(url: person.user.largeAvatarURL ?? person.user.avatarURL) { image in
                            SCArtistCard(
                                name: person.user.displayName,
                                subtitle: person.followerCountLabel,
                                avatarImage: image,
                                identity: person.user.id,
                                crownUser: person.user,
                                crownContext: person.user.displayName,
                                style: .mac
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .macCardHover(shape: .circle, play: { Task { await MacPlayback.play(user: person.user) } }) {
                        MacArtistContextMenu(artist: person.user)
                    }
                    .accessibilityHint("Opens the profile")

                    Text(person.followedLabel ?? " ")
                        .font(.caption)
                        .foregroundStyle(MacSecondaryStyle())
                        .lineLimit(1)
                        .accessibilityHidden(person.followedLabel == nil)

                    PersonFollowButton(user: person.user, model: model)
                }
            }
        }
    }
}

struct MacPeopleGrid: View {
    let people: [User]
    let pager: Paginator<User>
    var pagesOnScroll = true

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 20)],
                alignment: .leading,
                spacing: 24
            ) {
                ForEach(people) { person in
                    NavigationLink(value: person) {
                        SCArtworkResolver(url: person.largeAvatarURL ?? person.avatarURL) { image in
                            SCArtistCard(
                                name: person.displayName,
                                avatarImage: image,
                                identity: person.id,
                                crownUser: person,
                                crownContext: person.displayName,
                                style: .mac
                            )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .macCardHover(shape: .circle, play: { Task { await MacPlayback.play(user: person) } }) {
                        MacArtistContextMenu(artist: person)
                    }
                    .accessibilityHint("Opens the profile")
                    .onAppear {
                        guard pagesOnScroll else { return }
                        pager.loadMoreIfNeeded(after: person, lead: 12)
                    }
                }
            }
            if pagesOnScroll {
                MacPagedFooter(pager: pager)
            }
        }
    }
}

struct MacActivityPage: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var poller = SoundCloudActivityPoller.shared

    var body: some View {
        Group {
            if credentials.isSessionRejected {
                MacAccountRecoveryEmptyState(sectionName: "Activity")
            } else if poller.inbox.isEmpty {
                ContentUnavailableView(
                    "No New Activity",
                    systemImage: "bell",
                    description: Text("New followers, messages and Following activity appear here.")
                )
                .macFillsPane()
            } else {
                MacActivityInboxList(showsHeader: false)
            }
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItem(id: "activity-mark-all-read", placement: .primaryAction) {
                Button("Mark All Read") { poller.markAllRead() }
                    .disabled(poller.unreadCount == 0)
            }
        }
    }
}

struct MacActivityInboxList: View {
    var showsHeader = true
    var onNavigate: () -> Void = {}

    @ObservedObject private var poller = SoundCloudActivityPoller.shared

    var body: some View {
        List {
            Section {
                ForEach(poller.inbox) { event in
                    Button {
                        open(event)
                    } label: {
                        MacActivityInboxRow(event: event)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(event.readAt == nil ? "Unread" : "")
                    .accessibilityHint(event.kind == .feed ? (event.destination == nil ? "" : "Opens on SoundCloud") : "")
                }
            } header: {
                if showsHeader {
                    HStack {
                        Text("Activity")
                        Spacer()
                        if poller.unreadCount > 0 {
                            Button("Mark All Read") { poller.markAllRead() }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    private func open(_ event: SoundCloudInboxEvent) {
        poller.markRead(id: event.id)
        switch event.kind {
        case .follower:
            MacRootSelection.shared.request(.followers)
            onNavigate()
        case .message:
            MacRootSelection.shared.request(.messages)
            onNavigate()
        case .feed:
            if let destination = event.destination {
                NSWorkspace.shared.open(destination)
            }
        }
    }
}

private struct MacActivityInboxRow: View {
    let event: SoundCloudInboxEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(event.readAt == nil ? Color.scAccent : Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.body.weight(event.readAt == nil ? .semibold : .regular))
                    .lineLimit(1)
                Text(event.body)
                    .font(.subheadline)
                    .foregroundStyle(MacSecondaryStyle())
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Text(event.date, style: .relative)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch event.kind {
        case .feed: return "waveform"
        case .follower: return "person.badge.plus"
        case .message: return "envelope"
        }
    }
}
