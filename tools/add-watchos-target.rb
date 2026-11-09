#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds the `SoundingTV watchOS` application target to SoundingTV.xcodeproj.
#
# Run it from the repo root, against a quiet tree:
#
#     ruby tools/add-watchos-target.rb                    # the real project
#     ruby tools/add-watchos-target.rb /tmp/copy/Foo.xcodeproj
#
# Idempotent: re-running removes the existing target first and rebuilds it,
# so a partially-applied run is recoverable without hand-editing the pbxproj.
#
# ---------------------------------------------------------------------------
# Why this is a script and not an Xcode session
#
# Same reason as tools/add-macos-target.rb: `project.pbxproj` is a
# serialization bottleneck that has been corrupted once already by concurrent
# edits. A script is reviewable, repeatable, and testable against a copy.
# It obeys the same two xcodeproj-gem rules recorded in CLAUDE.md:
#
#   1. Anchor a file by its group's resolved absolute directory, pass the
#      *basename* as the reference path, and never touch a group's
#      `source_tree`.
#   2. Never set MARKETING_VERSION or CURRENT_PROJECT_VERSION at target level.
#
# ---------------------------------------------------------------------------
# Why the exclusion list is long, and why each entry cites a verified fact
#
# watchOS is the most constrained platform in this project. Every exclusion
# below was checked against the installed **watchOS 27.0 SDK** with
# `swiftc -typecheck -target arm64_32-apple-watchos27.0`, or against Apple
# TN3135 for the networking rules. The four SDK facts that drive most of it:
#
#   * `import AudioToolbox`   -> no such module   (kills MixEngine)
#   * `import WebKit`         -> no such module   (kills the OAuth web view)
#   * iOS-only UI frameworks -> no such module   (breaks the watch target)
#   * `UIApplication`         -> unavailable      (kills PlayerService's
#                                                  lifecycle observer)
#
# And the runtime one, which no compiler will tell you:
#
#   * Bonjour / NWBrowser / NWListener / raw TCP are blocked on watchOS
#     outside three narrow exceptions (TN3135). This code *compiles* and even
#     *works in the Simulator*, then fails with ENETDOWN on real hardware.
#     That is why the whole peer/pairing stack is excluded rather than merely
#     left unused.
#
# Membership is derived from the iOS target minus these exclusions, so new
# shared code joins the watch build by default and any file that does not
# belong there fails loudly and immediately.
# ---------------------------------------------------------------------------

require 'xcodeproj'
require 'pathname'

PROJECT_PATH = ARGV[0] || File.expand_path('../SoundingTV.xcodeproj', __dir__)
TARGET_NAME  = 'SoundingTV watchOS'
HOST_TARGET  = 'SoundingTV iOS'
BUNDLE_ID    = 'red.forbes.sounding.watchkitapp'
DEPLOYMENT   = '27.0'

project = Xcodeproj::Project.open(PROJECT_PATH)
root    = File.dirname(File.expand_path(PROJECT_PATH))

SHARED_EXCLUDE = {
  # --- SDK modules that do not exist on watchOS ---------------------------
  'Core/DJ/MixEngine.swift' => 'imports AudioToolbox, absent from the watchOS SDK; and DJ audio stays on the phone',
  'Auth/Shared/PhoneCredentialSource.swift' => 'AuthWebSession needs WebKit, absent from the watchOS SDK; the watch uses WatchCredentialSource',
  # --- symbols marked unavailable on watchOS ------------------------------
  'Core/Playback/PlayerService.swift' => 'UIApplication lifecycle notifications are unavailable on watchOS; the watch is a remote, not a player',
  'Core/Playback/PlaybackStateStore.swift' => 'persists a local playback queue the watch never has; the phone owns the queue',
  'Core/Library/LikesSyncEngine.swift' => 'UIApplication.didBecomeActiveNotification is unavailable on watchOS',
  'Shared/Design/Tokens.swift' => 'SCAmbient uses UIGraphicsImageRenderer, unavailable on watchOS',

  # --- TN3135: local networking is blocked at runtime ---------------------
  'Auth/Shared/BonjourAuthClient.swift' => 'TN3135 blocks Bonjour on watchOS; the watch never pairs with the TV directly',
  'Core/Networking/PeerContentTransport.swift' => 'TN3135 blocks NWListener/NWConnection on watchOS',
  'Core/Networking/PeerContentAssetLoaderDelegate.swift' => 'depends on PeerContentClient, which TN3135 blocks',

  # --- bound to PlayerService ---------------------------------------------
  'Core/Playback/SystemNowPlayingBridge.swift' => 'bound to PlayerService, which is excluded',
  'Core/Playback/MediaSessionNowPlayingBridge.swift' => 'bound to PlayerService, which is excluded',
  'Shared/UI/Components/PlayActions.swift' => 'calls PlayerService, which is excluded',
  'Shared/AppIntents/SoundCloudAppEntities.swift' => 'bound to PlayerService, which is excluded',
  'Shared/AppIntents/SoundCloudPlaybackIntents.swift' => 'bound to PlayerService, which is excluded',

  # --- work the phone does, that the watch only displays ------------------
  #
  # The Analysis and DJ clusters are mutually entangled (see the
  # CYCLE_ALLOWLIST in tools/check-layering.rb): AnalysisCache needs
  # AnalysisSync needs AnalysisProducers, and DJCore needs DJTemplates needs
  # PhantomDJEngine. They cannot be taken apart file by file, so they leave
  # together. The watch does not analyse audio or plan transitions — it
  # renders a WatchDJState the phone computed and sent over WatchConnectivity.
  'Core/Analysis/AnalysisCache.swift' => 'entangled with the analysis sync cluster; the watch does not analyse audio',
  'Core/Analysis/AnalysisDataUsage.swift' => 'reports on AnalysisCache, which is excluded',
  'Core/Analysis/GenreSelfTest.swift' => 'reuses MixImportSelfTest from MixEngine, which is excluded',
  'Core/DJ/CuePoints.swift' => 'DJ vocabulary; unused without the DJ engine',
  'Core/DJ/DJCore.swift' => 'entangled with DJTemplates and PhantomDJEngine, both excluded',
  'Core/DJ/DJProfiles.swift' => 'DJ profiles are chosen on the phone',
  'Shared/UI/Components/AnalysisLookup.swift' => 'reads AnalysisCache, which is excluded',
  'Shared/ViewModels/TrackSort.swift' => 'sorts by analysis data the watch does not hold',
  'Shared/UI/Setlist/SetlistViews.swift' => 'SwiftUI Menu is unavailable on watchOS',
  'Core/DJ/CueBoard.swift' => 'DJ computation stays on the phone; the watch renders the result',
  'Core/DJ/CueStore.swift' => 'DJ computation stays on the phone',
  'Core/DJ/CueSuggester.swift' => 'DJ computation stays on the phone',
  'Core/DJ/CueSelfTest.swift' => 'test harness for excluded DJ code',
  'Core/DJ/DJEngineSelfTest.swift' => 'test harness for excluded DJ code',
  'Core/DJ/DJScoringTerms.swift' => 'DJ track selection stays on the phone',
  'Core/DJ/DJTemplates.swift' => 'transition shaping belongs to MixEngine, which is excluded',
  'Core/DJ/PhantomDJEngine.swift' => 'transition planning stays on the phone; the watch shows the countdown',
  'Core/Analysis/AnalysisProducers.swift' => 'on-device audio analysis stays on the phone',
  'Core/Downloads/DownloadManager.swift' => 'downloading stays on the phone; the watch shows an inventory over WatchConnectivity',
  'Core/Downloads/CollectionQualityOverrides.swift' => 'download policy editing belongs to the phone UI',

  # --- CloudKit sync stack, dropped wholesale -----------------------------
  #
  # The watch receives credentials from the paired phone over
  # WatchConnectivity, which is both simpler and what the feature asks for.
  # These four are mutually dependent, so they leave together or not at all.
  'Core/Sync/CloudSyncEngine.swift' => 'watch credentials arrive over WatchConnectivity, not CloudKit',
  'Core/Analysis/AnalysisSync.swift' => 'part of the CloudKit sync stack',
  'Core/DJ/CueSync.swift' => 'part of the CloudKit sync stack',
  'Core/Downloads/DownloadManifestSync.swift' => 'part of the CloudKit sync stack'
}.freeze

SHARED_EXTRA = [].freeze

host_target = project.targets.find { |t| t.name == HOST_TARGET }
abort "Could not find the #{HOST_TARGET.inspect} target to derive membership from." if host_target.nil?

swiftpm_prefix = File.join(root, 'SoundingTV.swiftpm', 'Sources') + '/'

derived = host_target.source_build_phase.files.to_a.map do |bf|
  next nil unless bf.file_ref
  path = bf.file_ref.real_path.to_s
  next nil unless path.start_with?(swiftpm_prefix)
  path.delete_prefix(swiftpm_prefix)
end.compact.sort.uniq

unknown_exclusions = SHARED_EXCLUDE.keys - derived
unless unknown_exclusions.empty?
  warn "Exclusions no longer present in #{HOST_TARGET} (stale?):\n  #{unknown_exclusions.join("\n  ")}"
end

SHARED = (derived - SHARED_EXCLUDE.keys + SHARED_EXTRA).sort.uniq.freeze

puts "Shared files derived from #{HOST_TARGET.inspect}: #{derived.count} found, " \
     "#{(SHARED_EXCLUDE.keys & derived).count} excluded, #{SHARED_EXTRA.count} watch-only added " \
     "=> #{SHARED.count}."

watch_prefix = File.join(root, 'SoundingTV-watchOS', 'Sources') + '/'
WATCH = Dir.glob(File.join(watch_prefix, '**', '*.swift')).map do |path|
  path.delete_prefix(watch_prefix)
end.sort.freeze

abort 'No sources found under SoundingTV-watchOS/Sources.' if WATCH.empty?
puts "Watch-only sources: #{WATCH.count}."

# ---------------------------------------------------------------------------

existing = project.targets.find { |t| t.name == TARGET_NAME }
if existing
  warn "Removing existing target #{TARGET_NAME.inspect} before rebuilding it."
  # Drop the host's embed phase and dependency first, or they dangle.
  host_target.build_phases.select { |ph|
    ph.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) && ph.name == 'Embed Watch Content'
  }.each(&:remove_from_project)
  host_target.dependencies.select { |d| d.target == existing }.each(&:remove_from_project)
  existing.build_phases.each(&:remove_from_project)
  existing.remove_from_project
end

target = project.new_target(:application, TARGET_NAME, :watchos, DEPLOYMENT)

target.build_configurations.each do |config|
  config.build_settings.merge!(
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
    'CLANG_ENABLE_OBJC_WEAK' => 'NO',
    'CODE_SIGN_ENTITLEMENTS' => 'SoundingTV-watchOS/SoundingTV-watchOS.entitlements',
    'CODE_SIGN_STYLE' => 'Automatic',
    'ENABLE_PREVIEWS' => 'YES',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => 'SoundingTV-watchOS/Info.plist',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/Frameworks'],
    # LibraryCache and AnalysisCache link sqlite3 directly, same as iOS/tvOS.
    'OTHER_LDFLAGS' => ['$(inherited)', '-lsqlite3'],
    'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'SDKROOT' => 'watchos',
    'SKIP_INSTALL' => 'YES',
    'SWIFT_VERSION' => '6.0',
    'TARGETED_DEVICE_FAMILY' => '4',
    'WATCHOS_DEPLOYMENT_TARGET' => DEPLOYMENT
  )
  config.build_settings.delete('SUPPORTS_MACCATALYST')
end

# --- File references -------------------------------------------------------

def group_for_directory(project, root, relative_dir)
  wanted = Pathname.new(File.join(root, relative_dir)).cleanpath

  found = project.main_group.recursive_children.find do |child|
    next false unless child.is_a?(Xcodeproj::Project::Object::PBXGroup)
    begin
      child.real_path.cleanpath == wanted
    rescue StandardError
      false
    end
  end
  return found if found

  relative_dir.split('/').inject(project.main_group) do |parent, component|
    parent.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.path == component } ||
      parent.new_group(component, component)
  end
end

def reference(project, root, relative_dir, basename)
  group = group_for_directory(project, root, relative_dir)
  group.files.find { |f| f.path == basename } || group.new_reference(basename)
end

refs = []
SHARED.each do |f|
  refs << reference(project, root, "SoundingTV.swiftpm/Sources/#{File.dirname(f)}", File.basename(f))
end
WATCH.each do |f|
  refs << reference(project, root, "SoundingTV-watchOS/Sources/#{File.dirname(f)}", File.basename(f))
end

target.add_file_references(refs)

assets = reference(project, root, 'SoundingTV-watchOS', 'Assets.xcassets')
target.add_resources([assets])

# --- Embed into the iOS host ------------------------------------------------
#
# A watch app ships inside its companion iOS app's bundle at
# `$(CONTENTS_FOLDER_PATH)/Watch`. Without this phase the target builds and
# runs in the Simulator but never installs alongside the phone app.

host_target.add_dependency(target)

embed = host_target.new_copy_files_build_phase('Embed Watch Content')
embed.symbol_dst_subfolder_spec = :products_directory
embed.dst_path = '$(CONTENTS_FOLDER_PATH)/Watch'
build_file = embed.add_file_reference(target.product_reference, true)
build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

# --- Sanity checks ---------------------------------------------------------

missing = target.source_build_phase.files.map { |bf| bf.file_ref.real_path.to_s }
                .reject { |p| File.exist?(p) }
unless missing.empty?
  abort "Missing source files:\n  #{missing.join("\n  ")}"
end

%w[
  SoundingTV-watchOS/Info.plist
  SoundingTV-watchOS/SoundingTV-watchOS.entitlements
  SoundingTV-watchOS/Assets.xcassets
].each do |p|
  abort "Missing #{p}" unless File.exist?(File.join(root, p))
end

if target.source_build_phase.files.count.zero?
  abort 'Target has no source files; refusing to save.'
end

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(PROJECT_PATH, TARGET_NAME, true)

puts "Added #{TARGET_NAME}: #{target.source_build_phase.files.count} source files, " \
     "embedded into #{HOST_TARGET}."
puts 'Build with:'
puts "  xcodebuild -project #{File.basename(PROJECT_PATH)} -scheme '#{TARGET_NAME}' \\"
puts "    -destination 'platform=watchOS Simulator,name=Apple Watch Series 10 (46mm)' build"
