import SwiftUI

struct PersonFollowButton: View {
    let user: User
    @ObservedObject var model: PeopleDirectoryModel
    @State private var confirmsUnfollow = false

    var body: some View {
        let following = model.isFollowing(user)
        Button {
            if following {
                confirmsUnfollow = true
            } else {
                model.setFollowing(true, user)
            }
        } label: {
            Text(following ? "Following" : "Follow")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        #if !os(tvOS)
        .controlSize(.small)
        .fixedSize()
        #endif
        .confirmationDialog("Unfollow \(user.displayName)?", isPresented: $confirmsUnfollow, titleVisibility: .visible) {
            Button("Unfollow", role: .destructive) { model.setFollowing(false, user) }
        }
        .accessibilityLabel(following ? "Unfollow \(user.displayName)" : "Follow \(user.displayName)")
        .accessibilityValue(following ? "Following" : "Not following")
    }
}

extension PeopleDirectoryModel {
    var emptyTitle: String {
        kind == .following ? "Not Following Anyone" : "No Followers Yet"
    }

    var emptyMessage: String {
        kind == .following
            ? "Artists you follow on SoundCloud appear here."
            : "People who follow you on SoundCloud appear here."
    }
}

extension View {
    func peopleActionAlert(_ model: PeopleDirectoryModel) -> some View {
        alert("Couldn\u{2019}t Update Follow", isPresented: Binding(
            get: { model.actionFailure != nil },
            set: { if !$0 { model.actionFailure = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionFailure ?? "")
        }
    }
}

struct PeopleSortMenu: View {
    @ObservedObject var model: PeopleDirectoryModel
    var showsSelection = false

    var body: some View {
        Menu {
            Picker("Sort By", selection: $model.sort) {
                ForEach(PeopleSort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(showsSelection ? "Sort: \(model.sort.title)" : "Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityValue(model.sort.title)
    }
}

#if os(iOS) || os(macOS)
struct PeopleDirectoryView<Content: View>: View {
    @ObservedObject var model: PeopleDirectoryModel
    let content: ([PersonEntry]) -> Content

    @State private var query = ""
    @State private var isSearchPresented = false
    #if os(macOS)
    @ObservedObject private var findFocus = MacFindFocus.shared
    #endif

    init(model: PeopleDirectoryModel, @ViewBuilder content: @escaping ([PersonEntry]) -> Content) {
        _model = ObservedObject(wrappedValue: model)
        self.content = content
    }

    var body: some View {
        let people = model.visible(matching: query)
        states(people)
            .navigationTitle(model.kind.rawValue)
            #if os(macOS)
            .searchable(text: $query, isPresented: $isSearchPresented, placement: .toolbar, prompt: "Find in \(model.kind.rawValue)")
            .onReceive(findFocus.$request.dropFirst()) { _ in isSearchPresented = true }
            #else
            .searchable(text: $query, prompt: "Search \(model.kind.rawValue)")
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    PeopleSortMenu(model: model)
                        .disabled(model.entries.isEmpty)
                }
            }
            .peopleActionAlert(model)
            .task { await model.load() }
    }

    @ViewBuilder
    private func states(_ people: [PersonEntry]) -> some View {
        if model.showsLoading {
            #if os(macOS)
            LoadingPlaceholder(.grid(minimumTile: 140, circular: true))
            #else
            LoadingPlaceholder(.trackList(.phoneRoomy))
            #endif
        } else if model.entries.isEmpty {
            ContentUnavailableView(
                model.emptyTitle,
                systemImage: model.kind.systemImage,
                description: Text(model.emptyMessage)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if people.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content(people)
        }
    }
}
#endif
