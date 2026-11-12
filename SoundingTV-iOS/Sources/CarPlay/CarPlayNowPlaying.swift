import CarPlay
import UIKit

struct CarPlayNowPlayingState: Equatable {
    let trackID: String?
    let canLike: Bool
    let isLiked: Bool
    let isAutoMixOn: Bool
    let canMixNow: Bool
}

extension CarPlayController {
    func configureNowPlaying() {
        let template = nowPlayingTemplate
        template.isUpNextButtonEnabled = true
        template.upNextTitle = "Up Next"
        template.isAlbumArtistButtonEnabled = true
        if #available(iOS 27.0, *) {
            template.allowsMiniPlayer = true
        }
        template.add(self)
        nowPlayingState = nil
        refreshNowPlaying()
    }

    func refreshNowPlaying() {
        guard isRunning else { return }
        let snapshot = coordinator.nowPlaying
        let trackID = snapshot?.trackId
        let allowsLike = snapshot.map { self.canLike($0) } ?? false
        if trackID != nowPlayingState?.trackID, let trackID, allowsLike {
            likes.refresh(trackId: trackID, resolved: coordinator.currentTrack)
        }
        let dj = coordinator.djSnapshot
        let state = CarPlayNowPlayingState(
            trackID: trackID,
            canLike: allowsLike,
            isLiked: allowsLike && trackID.map { likes.isLiked($0, resolved: coordinator.currentTrack) } == true,
            isAutoMixOn: dj.isAutoEnabled,
            canMixNow: dj.isAutoEnabled && coordinator.canMixNow
        )
        guard state != nowPlayingState else { return }
        nowPlayingState = state

        var buttons: [CPNowPlayingButton] = []
        if state.canLike {
            let like = CPNowPlayingImageButton(image: CarPlaySymbol.image(state.isLiked ? "heart.fill" : "heart")) { [weak self] _ in
                MainActor.assumeIsolated { self?.toggleLike() }
            }
            like.isSelected = state.isLiked
            buttons.append(like)
        }
        let autoMix = CPNowPlayingImageButton(image: CarPlaySymbol.image("infinity")) { [weak self] _ in
            MainActor.assumeIsolated { self?.toggleAutoMix() }
        }
        autoMix.isSelected = state.isAutoMixOn
        buttons.append(autoMix)
        if state.canMixNow {
            buttons.append(CPNowPlayingImageButton(image: CarPlaySymbol.image("arrow.triangle.merge")) { [weak self] _ in
                MainActor.assumeIsolated { self?.coordinator.mixNow() }
            })
        }
        nowPlayingTemplate.updateNowPlayingButtons(buttons)
    }

    private func toggleLike() {
        guard let snapshot = coordinator.nowPlaying, let trackID = snapshot.trackId, canLike(snapshot) else { return }
        likes.toggle(trackId: trackID, resolved: coordinator.currentTrack)
        refreshNowPlaying()
        NowPlayingFeedbackCommands.shared.refresh()
    }

    private func toggleAutoMix() {
        let dj = coordinator.djSnapshot
        if dj.isAutoEnabled {
            coordinator.setDJEnabled(false)
            coordinator.setAutoMixEnabled(false)
        } else if dj.isEngineLive {
            coordinator.setAutoMixEnabled(true)
        } else {
            coordinator.startDJSession(configuration: SettingsStore.shared.djStartConfiguration)
        }
    }

    func showUpNext() {
        let template = CPListTemplate(title: "Up Next", sections: [])
        template.emptyViewTitleVariants = ["Nothing Up Next"]
        upNextTemplate = template
        upNextRevision = nil
        refreshUpNext()
        push(template)
    }

    func refreshUpNext() {
        guard let template = upNextTemplate else { return }
        let entries = Array(coordinator.upNextEntries.prefix(Int(CPListTemplate.maximumItemCount)))
        let revision = entries.map(\.id)
        guard revision != upNextRevision else { return }
        upNextRevision = revision
        let items = entries.enumerated().map { index, entry in
            let item = CPListItem(text: entry.title, detailText: entry.artist)
            item.handler = { [weak self] _, completion in
                MainActor.assumeIsolated {
                    if let queueIndex = entry.queueIndex { self?.coordinator.playQueueItem(at: queueIndex) }
                    self?.showNowPlaying()
                }
                completion()
            }
            let url = entry.artworkURL.flatMap(URL.init(string:))
            loadArtwork(into: item, url: url, symbol: "music.note", loads: index < CarPlayArtwork.perListLimit)
            return item
        }
        template.updateSections(items.isEmpty ? [] : [CPListSection(items: items)])
    }

    func showNowPlayingArtist() {
        guard let snapshot = coordinator.nowPlaying, let name = snapshot.artist, !name.isEmpty else { return }
        let track = coordinator.currentTrack
        let userID = track.flatMap { $0.isLocal ? nil : $0.user.id }
        pushArtist(name: name, userID: userID)
    }

    func pushArtist(name: String, userID: String?) {
        var leading: [CPListItem] = []
        if let userID, isSignedIn {
            leading.append(actionItem("Play \(name)", symbol: "play.fill") { [weak self] in
                self?.perform { try await IntentPlayback.playArtist(id: userID) }
            })
        }
        let limit = Int(CPListTemplate.maximumItemCount)
        pushTracks(
            title: name,
            emptyTitle: "Nothing in Your Library",
            collectionId: nil,
            shuffles: leading.isEmpty,
            leading: leading
        ) {
            await ListeningCatalog.libraryTracks(byArtist: name, userID: userID, limit: limit)
        }
    }
}

extension CarPlayController: @preconcurrency CPNowPlayingTemplateObserver {
    func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        showUpNext()
    }

    func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        showNowPlayingArtist()
    }
}
