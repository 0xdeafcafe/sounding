import SwiftUI

struct SocialSectionView: View {
    let section: SocialSection

    var body: some View {
        switch section {
        case .following:
            SoundCloudSectionGate(.following) { OwnPeopleView(kind: .following) }
        case .followers:
            SoundCloudSectionGate(.followers) { OwnPeopleView(kind: .followers) }
        case .profile:
            SoundCloudSectionGate(.profile) { ProfileView() }
        case .activity:
            PhoneActivityInboxView()
        }
    }
}

private struct OwnPeopleView: View {
    @StateObject private var model: PeopleDirectoryModel

    init(kind: ArtistConnectionKind) {
        _model = StateObject(wrappedValue: PeopleDirectoryModel(kind: kind))
    }

    var body: some View {
        PeopleDirectoryView(model: model) { people in
            List(people) { person in
                NavigationLink {
                    ArtistDetailView(user: person.user)
                } label: {
                    PersonRow(person: person, model: model)
                }
                .libraryRowPreviewShape()
                .contextMenu { UserContextMenu(user: person.user) }
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PersonRow: View {
    let person: PersonEntry
    @ObservedObject var model: PeopleDirectoryModel

    var body: some View {
        HStack(spacing: Spacing.md) {
            ArtworkThumbnail(
                url: person.user.avatarURL,
                systemImage: "person.fill",
                isCircle: true,
                identity: person.user.id,
                crownUser: person.user,
                crownContext: person.user.displayName
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(person.user.displayName)
                    .font(.scBody)
                    .scAdaptiveLineLimit()
                Text(person.detail)
                    .font(.scSubhead)
                    .foregroundStyle(.secondary)
                    .scAdaptiveLineLimit()
            }

            Spacer(minLength: Spacing.sm)

            PersonFollowButton(user: person.user, model: model)
        }
        .padding(.vertical, Spacing.xs)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 52 + Spacing.md }
    }
}
