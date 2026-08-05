#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time, idempotent migration from the repository's flat source layout to
# feature-owned Core / Shared / Auth / per-app trees. Xcode file references are
# re-parented instead of recreated so every target keeps its existing compile
# membership and build-file UUIDs.

require 'fileutils'
require 'pathname'
require 'xcodeproj'

ROOT = Pathname.new(__dir__).join('..').expand_path
PROJECT_PATH = ROOT.join('SoundingTV.xcodeproj')
APPLY = ARGV.delete('--apply')
abort "Usage: #{File.basename($PROGRAM_NAME)} [--apply]" unless ARGV.empty?

moves = {}

add = lambda do |source, destination|
  source = ROOT.join(source).cleanpath
  destination = ROOT.join(destination).cleanpath
  abort "Duplicate source mapping: #{source}" if moves.key?(source)
  abort "Duplicate destination mapping: #{destination}" if moves.value?(destination)
  moves[source] = destination
end

add_group = lambda do |source_directory, destination_directory, basenames|
  basenames.each do |basename|
    add.call("#{source_directory}/#{basename}", "#{destination_directory}/#{basename}")
  end
end

# Core domain code.
add_group.call('SoundingTV.swiftpm/Sources/Models', 'SoundingTV.swiftpm/Sources/Core/Models', %w[
  Comment.swift Discovery.swift DiscoveryDecodeSelfTest.swift FeedActivity.swift
  Playlist.swift Track.swift User.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Design', 'SoundingTV.swiftpm/Sources/Core/Artwork', %w[
  ArtworkStore.swift ArtworkVariant.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/Analysis', %w[
  AnalysisCache.swift AnalysisProducers.swift AnalysisSync.swift GenreDetection.swift
  GenreDetector.swift GenreDistance.swift GenreSelfTest.swift GenreTaxonomy.swift
  LoudnessSelfTest.swift WaveformService.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/DJ', %w[
  CueBoard.swift CuePoints.swift CueSelfTest.swift CueStore.swift CueSuggester.swift
  CueSync.swift DJCore.swift DJEngineSelfTest.swift DJProfiles.swift DJScoringTerms.swift
  DJTemplates.swift MixEngine.swift PhantomDJEngine.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/Downloads', %w[
  CollectionQualityOverrides.swift DownloadManager.swift DownloadManifestSync.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/Library', %w[
  LibraryCache.swift LikesSyncEngine.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/Networking', %w[
  PeerContentAssetLoaderDelegate.swift PeerContentTransport.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/Playback', %w[
  AudioSessionCoordinator.swift MediaSessionNowPlayingBridge.swift PlaybackStateStore.swift
  PlayerService.swift RemoteOutputTarget.swift SystemNowPlayingBridge.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/Settings', %w[
  SettingsStore.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/SoundCloud', %w[
  SoundCloudAPI.swift SubscriptionService.swift TrackActions.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/Sync', %w[
  CloudSyncEngine.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/Support', %w[
  Log.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Core/TopShelf', %w[
  TopShelfSnapshot.swift
])

# Cross-app auth. TokenTransferProtocol.swift below is the canonical copy; the
# byte-identical historical phone copy is merged into this file reference.
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Auth/Shared', %w[
  SessionSync.swift TokenTransferProtocol.swift
])
add_group.call('SoundingTV-Shared/Sources', 'SoundingTV.swiftpm/Sources/Auth/Shared', %w[
  BonjourAuthClient.swift PhoneSessionStore.swift
])
add.call(
  'SoundingTV-iOS/Sources/PhoneCredentialSource.swift',
  'SoundingTV.swiftpm/Sources/Auth/Shared/PhoneCredentialSource.swift'
)

# Reusable design, view-model, intent, and UI seams.
add_group.call('SoundingTV.swiftpm/Sources/AppIntents', 'SoundingTV.swiftpm/Sources/Shared/AppIntents', %w[
  SoundCloudAppEntities.swift SoundCloudPlaybackIntents.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Design', 'SoundingTV.swiftpm/Sources/Shared/Design', %w[
  AnalysisBadge.swift ArtworkResolver.swift CommentRail.swift ContentComponents.swift
  ContentStyle.swift GeneratedArtwork.swift Tokens.swift WaveformRenderer.swift
])
add_group.call('SoundingTV.swiftpm/Sources/ViewModels', 'SoundingTV.swiftpm/Sources/Shared/ViewModels', %w[
  ArtistDetailViewModel.swift DiscoveryHomeSource.swift FeedViewModel.swift
  PlaylistDetailViewModel.swift TrackSort.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Views/Comments', 'SoundingTV.swiftpm/Sources/Shared/UI/Comments', %w[
  CommentThreads.swift SCCommentRow.swift
])
add_group.call('SoundingTV.swiftpm/Sources/Views/Components', 'SoundingTV.swiftpm/Sources/Shared/UI/Components', %w[
  AnalysisLookup.swift ArtworkImage.swift PlayActions.swift PulseTimeline.swift
])

# tvOS app-only implementation.
add_group.call('SoundingTV.swiftpm/Sources/App', 'SoundingTV.swiftpm/Sources/Apps/tvOS/App', %w[
  SoundingTVApp.swift
])
add.call('SoundingTV.swiftpm/Sources/Views/RootView.swift', 'SoundingTV.swiftpm/Sources/Apps/tvOS/App/RootView.swift')
add_group.call('SoundingTV.swiftpm/Sources/Services', 'SoundingTV.swiftpm/Sources/Apps/tvOS/Auth', %w[
  AuthenticationService.swift BonjourAuthServer.swift KeychainService.swift QRCodeGenerator.swift
])
add.call(
  'SoundingTV.swiftpm/Sources/Views/Login/QRCodeLoginView.swift',
  'SoundingTV.swiftpm/Sources/Apps/tvOS/Auth/QRCodeLoginView.swift'
)
add_group.call('SoundingTV.swiftpm/Sources/Design', 'SoundingTV.swiftpm/Sources/Apps/tvOS/Design', %w[
  DesignSystem.swift GlassComponents.swift
])
add.call(
  'SoundingTV.swiftpm/Sources/Design/Shaders/CardEffects.metal',
  'SoundingTV.swiftpm/Sources/Apps/tvOS/Design/Shaders/CardEffects.metal'
)
add.call(
  'SoundingTV.swiftpm/Sources/Services/ArtworkColors.swift',
  'SoundingTV.swiftpm/Sources/Apps/tvOS/Design/ArtworkColors.swift'
)
add_group.call('SoundingTV.swiftpm/Sources/Views/Comments', 'SoundingTV.swiftpm/Sources/Apps/tvOS/Features/Comments', %w[
  CommentsListView.swift
])
%w[Feed Home Library Player Profile Search Settings].each do |feature|
  source = ROOT.join("SoundingTV.swiftpm/Sources/Views/#{feature}")
  next unless source.directory?
  source.children.select(&:file?).each do |file|
    add.call(
      file.relative_path_from(ROOT).to_s,
      "SoundingTV.swiftpm/Sources/Apps/tvOS/Features/#{feature}/#{file.basename}"
    )
  end
end
add_group.call('SoundingTV.swiftpm/Sources/Views/Components', 'SoundingTV.swiftpm/Sources/Apps/tvOS/UI/Components', %w[
  PlaylistGridView.swift QRCodeView.swift TrackListView.swift UserGridView.swift
])
add.call(
  'SoundingTV.swiftpm/Sources/Services/RemoteQueueServer.swift',
  'SoundingTV.swiftpm/Sources/Apps/tvOS/Playback/RemoteQueueServer.swift'
)
add.call(
  'SoundingTV.swiftpm/Sources/Services/TopShelfPublisher.swift',
  'SoundingTV.swiftpm/Sources/Apps/tvOS/TopShelf/TopShelfPublisher.swift'
)

# iOS app.
add_group.call('SoundingTV-iOS/Sources', 'SoundingTV-iOS/Sources/App', %w[
  PhoneAppState.swift PhoneRootView.swift SoundingTViOSApp.swift
])
add.call('SoundingTV-Shared/Sources/SoundCloudLoginView.swift', 'SoundingTV-iOS/Sources/Auth/SoundCloudLoginView.swift')
add.call('SoundingTV-Shared/Sources/PhoneDesign.swift', 'SoundingTV.swiftpm/Sources/Shared/Design/PhoneDesign.swift')
add_group.call('SoundingTV-iOS/Sources', 'SoundingTV-iOS/Sources/Features/AppleTV', %w[
  CompanionRootView.swift DJControlView.swift QueueManagerView.swift RemoteQueueClient.swift
])
add_group.call('SoundingTV-iOS/Sources', 'SoundingTV-iOS/Sources/Features/Feed', %w[FeedView.swift])
add_group.call('SoundingTV-iOS/Sources', 'SoundingTV-iOS/Sources/Features/Home', %w[PhoneHomeView.swift])
add_group.call('SoundingTV-iOS/Sources', 'SoundingTV-iOS/Sources/Features/Library', %w[
  ArtistDetailView.swift CollectionDownloadButton.swift LibraryBrowserView.swift
  PlaylistDetailView.swift TrackSortMenu.swift
])
add_group.call('SoundingTV-iOS/Sources', 'SoundingTV-iOS/Sources/Features/Profile', %w[ProfileView.swift])
add_group.call('SoundingTV-iOS/Sources', 'SoundingTV-iOS/Sources/Features/Search', %w[GlobalSearchView.swift])
add_group.call('SoundingTV-iOS/Sources', 'SoundingTV-iOS/Sources/Features/Settings', %w[PhoneSettingsView.swift])
add_group.call('SoundingTV-iOS/Sources', 'SoundingTV-iOS/Sources/Playback', %w[
  PhonePlaybackCoordinator.swift TransportBarView.swift
])
add.call('SoundingTV-iOS/Sources/CuePickerView.swift', 'SoundingTV-iOS/Sources/Playback/TrackMapSheet.swift')
add_group.call('SoundingTV-iOS/Sources', 'SoundingTV-iOS/Sources/Services', %w[SpotlightIndexingService.swift])

# macOS app.
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/App', %w[
  MacDecksCommands.swift MacKeyboardShortcutsSheet.swift MacRootView.swift SoundingMacApp.swift
])
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/Auth', %w[MacAccountView.swift])
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/Design', %w[
  MacArtworkCache.swift MacMaterials.swift MacPaneHeader.swift MacWindowChrome.swift
])
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/Features/DJ', %w[
  MIDIControllerHub.swift MIDIMixerBridge.swift MacConsoleView.swift MacDeckPanel.swift
  MacMixerControls.swift MacWaveformViews.swift
])
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/Features/Feed', %w[MacFeedView.swift])
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/Features/Home', %w[MacHomeView.swift])
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/Features/Library', %w[
  MacAlbumDetailView.swift MacArtistDetailView.swift MacLibraryBrowserView.swift
  MacPlaylistDetailView.swift MacPlaylistsView.swift MacTrackContextMenu.swift
])
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/Features/Playback', %w[
  MacNowPlayingView.swift MacQueueSidebar.swift MacTransportBar.swift
])
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/Features/Profile', %w[MacProfileView.swift])
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/Features/Search', %w[MacSearchView.swift])
add_group.call('SoundingTV-macOS/Sources', 'SoundingTV-macOS/Sources/Services', %w[
  MacAudioSessionCoordinator.swift MacSyncCoordinator.swift
])

# Extensions and UI tests.
add_group.call('SoundingTV-Widget/Sources', 'SoundingTV-Widget/Sources/App', %w[SoundingWidgetBundle.swift])
add_group.call('SoundingTV-Widget/Sources', 'SoundingTV-Widget/Sources/Intents', %w[PlaybackControlIntents.swift])
add_group.call('SoundingTV-Widget/Sources', 'SoundingTV.swiftpm/Sources/Shared/LiveActivity', %w[
  NowPlayingActivityAttributes.swift NowPlayingLiveActivity.swift
])
add_group.call('SoundingTV-Widget/Sources', 'SoundingTV-Widget/Sources/Services', %w[WidgetControlSender.swift])
add_group.call('SoundingTV-Widget/Sources', 'SoundingTV-Widget/Sources/Views', %w[
  NowPlayingLiveActivityWidget.swift
])
add_group.call('SoundingTV-Share/Sources', 'SoundingTV-Share/Sources/App', %w[ShareViewController.swift])
add_group.call('SoundingTV-Share/Sources', 'SoundingTV-Share/Sources/Models', %w[ShareDestination.swift])
add_group.call('SoundingTV-TopShelf', 'SoundingTV-TopShelf/Sources', %w[ContentProvider.swift DefaultShelf.swift])
add.call('SoundingTV-UITests/FocusWalkTests.swift', 'SoundingTV-UITests/Sources/FocusWalkTests.swift')

# Refuse to silently strand source code in one of the legacy buckets.
legacy_patterns = %w[
  SoundingTV.swiftpm/Sources/App/**/*.{swift,metal}
  SoundingTV.swiftpm/Sources/AppIntents/**/*.{swift,metal}
  SoundingTV.swiftpm/Sources/Design/**/*.{swift,metal}
  SoundingTV.swiftpm/Sources/Models/**/*.{swift,metal}
  SoundingTV.swiftpm/Sources/Services/**/*.{swift,metal}
  SoundingTV.swiftpm/Sources/ViewModels/**/*.{swift,metal}
  SoundingTV.swiftpm/Sources/Views/**/*.{swift,metal}
  SoundingTV-Shared/Sources/*.{swift,metal}
  SoundingTV-iOS/Sources/*.{swift,metal}
  SoundingTV-macOS/Sources/*.{swift,metal}
  SoundingTV-Widget/Sources/*.{swift,metal}
  SoundingTV-Share/Sources/*.{swift,metal}
  SoundingTV-TopShelf/*.{swift,metal}
  SoundingTV-UITests/*.{swift,metal}
]
legacy_sources = legacy_patterns.flat_map { |pattern| Dir.glob(ROOT.join(pattern).to_s) }
                               .map { |path| Pathname.new(path).cleanpath }
                               .uniq
unmapped = legacy_sources.reject do |source|
  moves.key?(source) ||
    source == ROOT.join('SoundingTV-Shared/Sources/TokenTransferProtocol.swift') ||
    source.basename.to_s == 'DemoSeed.swift'
end
abort "Unmapped legacy sources:\n  #{unmapped.join("\n  ")}" unless unmapped.empty?

missing = moves.keys.reject { |source| source.exist? || moves.fetch(source).exist? }
abort "Missing source and destination:\n  #{missing.join("\n  ")}" unless missing.empty?

puts "#{APPLY ? 'Applying' : 'Planned'} #{moves.length} source moves:"
moves.each do |source, destination|
  puts "  #{source.relative_path_from(ROOT)} -> #{destination.relative_path_from(ROOT)}"
end
exit unless APPLY

project = Xcodeproj::Project.open(PROJECT_PATH)

# A completed migration is a validation pass on subsequent runs.
if moves.values.all?(&:exist?)
  broken = project.files.map do |reference|
    next unless reference.last_known_file_type == 'sourcecode.swift' || reference.path.to_s.end_with?('.metal')
    path = reference.real_path.cleanpath
    path unless path.exist?
  end.compact
  abort "Broken Xcode source references:\n  #{broken.join("\n  ")}" unless broken.empty?
  puts 'Source tree is already organized and every Xcode source reference resolves.'
  exit
end

references_for = lambda do |path|
  project.files.select do |reference|
    begin
      reference.real_path.cleanpath == path
    rescue StandardError
      false
    end
  end
end

references_by_source = moves.to_h { |source, _destination| [source, references_for.call(source)] }

canonical_token = ROOT.join('SoundingTV.swiftpm/Sources/Services/TokenTransferProtocol.swift')
duplicate_token = ROOT.join('SoundingTV-Shared/Sources/TokenTransferProtocol.swift')
canonical_token_ref = references_for.call(canonical_token).first
duplicate_token_ref = references_for.call(duplicate_token).first
abort 'Canonical TokenTransferProtocol.swift Xcode reference not found' unless canonical_token_ref
abort 'Duplicate TokenTransferProtocol.swift Xcode reference not found' unless duplicate_token_ref
abort 'TokenTransferProtocol.swift copies diverged; refusing to discard either' unless FileUtils.compare_file(canonical_token, duplicate_token)

duplicate_token_targets = project.targets.select do |target|
  target.source_build_phase.files.any? { |build_file| build_file.file_ref == duplicate_token_ref }
end
duplicate_token_ref.remove_from_project
duplicate_token_targets.each do |target|
  next if target.source_build_phase.files.any? { |build_file| build_file.file_ref == canonical_token_ref }
  target.add_file_references([canonical_token_ref])
end
FileUtils.rm_f(duplicate_token)

moves.each do |source, destination|
  next if destination.exist?
  FileUtils.mkdir_p(destination.dirname)
  FileUtils.mv(source, destination)
end

group_for_directory = lambda do |relative_directory|
  wanted = ROOT.join(relative_directory).cleanpath
  candidates = [project.main_group] + project.main_group.recursive_children.grep(
    Xcodeproj::Project::Object::PBXGroup
  )
  anchor = candidates.select do |candidate|
    path = candidate.real_path.cleanpath
    next false if path == ROOT && candidate != project.main_group
    wanted.to_s == path.to_s || wanted.to_s.start_with?(path.to_s + '/')
  end.max_by { |candidate| candidate.real_path.cleanpath.to_s.length }
  abort "No Xcode group anchor for #{wanted}" unless anchor

  remaining = wanted.relative_path_from(anchor.real_path.cleanpath)
  remaining.each_filename.inject(anchor) do |parent, component|
    child_path = parent.real_path.join(component).cleanpath
    parent.groups.find { |child| child.real_path.cleanpath == child_path } ||
      parent.new_group(component, component)
  end
end

moves.each do |source, destination|
  group = group_for_directory.call(destination.dirname.relative_path_from(ROOT))
  references_by_source.fetch(source).each do |reference|
    reference.parent.children.delete(reference) if reference.parent
    group.children << reference
    reference.name = nil
    reference.path = destination.basename.to_s
    reference.source_tree = '<group>'
  end
end

project.save

# Remove only now-empty legacy directories plus the explicitly retired App
# Clip container. Every substantive App Clip source was moved above.
legacy_directories = legacy_patterns.map { |pattern| ROOT.join(pattern.split('/**').first).dirname }
legacy_directories.concat([
  ROOT.join('SoundingTV-Shared/Sources'),
  ROOT.join('SoundingTV-Shared'),
  ROOT.join('SoundingTV-AppClip/Sources')
])
legacy_directories.uniq.sort_by { |path| -path.to_s.length }.each do |directory|
  begin
    directory.rmdir if directory.directory? && directory.children.empty?
  rescue SystemCallError
    nil
  end
end
FileUtils.rm_f(ROOT.join('SoundingTV-AppClip/.DS_Store'))
begin
  ROOT.join('SoundingTV-AppClip').rmdir
rescue SystemCallError
  nil
end

broken_references = project.files.map do |reference|
  next unless reference.last_known_file_type == 'sourcecode.swift' || reference.path.to_s.end_with?('.metal')
  path = reference.real_path.cleanpath
  path unless path.exist?
end.compact
abort "Broken Xcode source references:\n  #{broken_references.join("\n  ")}" unless broken_references.empty?

puts "Moved #{moves.length} sources and preserved all Xcode target memberships."
