#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds the `SoundingTV macOS` application target to SoundingTV.xcodeproj.
#
# Run it from the repo root, against a quiet tree:
#
#     ruby tools/add-macos-target.rb                    # the real project
#     ruby tools/add-macos-target.rb /tmp/copy/Foo.xcodeproj
#
# Idempotent: re-running removes the existing target first and rebuilds it,
# so a partially-applied run is recoverable without hand-editing the pbxproj.
#
# ---------------------------------------------------------------------------
# Why this is a script and not an Xcode session
#
# `project.pbxproj` is a serialization bottleneck. Adding a whole target is a
# large mutation, and this file has already been corrupted once by concurrent
# edits. A script is reviewable, repeatable, and can be tested against a copy
# of the project before it ever touches the real one — which is exactly what
# was done here (see the verification block at the bottom of
# Design/specs/macos-plan.md §2).
#
# Two xcodeproj-gem rules this script obeys, both learned the hard way and
# recorded in CLAUDE.md:
#
#   1. Anchor a file by its group's exact `hierarchy_path`, pass the
#      *basename* as the reference path, and never touch a group's
#      `source_tree`. Setting a group's source tree to SOURCE_ROOT re-roots
#      every file already in it and the whole target fails with "Build input
#      files cannot be found".
#   2. Never set MARKETING_VERSION or CURRENT_PROJECT_VERSION at target
#      level. They are project-level and referenced as $(...) from every
#      Info.plist; a target-level override is a build warning and an App
#      Store Connect rejection.
# ---------------------------------------------------------------------------

require 'xcodeproj'
require 'pathname'

PROJECT_PATH = ARGV[0] || File.expand_path('../SoundingTV.xcodeproj', __dir__)
TARGET_NAME  = 'SoundingTV macOS'
BUNDLE_ID    = 'red.forbes.sounding'
DEPLOYMENT   = '27.0'

project = Xcodeproj::Project.open(PROJECT_PATH)
root    = File.dirname(File.expand_path(PROJECT_PATH))

# ---------------------------------------------------------------------------
# Source membership
#
# The shared set is **derived from the iOS target's membership**, not listed
# by hand.
#
# This started as a hand-written list of 33 files and broke within the hour:
# another agent added `Models/FeedActivity.swift` to the shared tree and the
# macOS build failed with "cannot find type 'FeedActivity' in scope". A
# hand-written list is a second source of truth that silently rots every time
# the shared layer grows, and the failure mode is a confusing scope error in
# an unrelated file rather than anything that points at the list.
#
# So the rule is stated once, positively: **macOS compiles whatever iOS
# compiles from `SoundingTV.swiftpm/Sources`, minus an explicit exclusion
# list with a reason attached to each entry.** New shared code is picked up
# automatically; anything genuinely platform-bound has to be named here,
# where the reason is visible.
#
# The script prints what it selected, so a run is reviewable.
# ---------------------------------------------------------------------------

# Files the iOS app compiles from the shared tree that macOS must NOT.
# Every entry needs a reason.
SHARED_EXCLUDE = {
  # UIKit-shaped throughout: `ArtworkImage` is a SwiftUI view built on
  # UIImage, and `ArtworkCache` vends UIImage. macOS supplies its own
  # `ArtworkCache` (MacArtworkCache.swift) vending NSImage, which is all
  # PlayerService actually needs — MPMediaItemArtwork is polymorphic across
  # the two.
  'Shared/UI/Components/ArtworkImage.swift' => 'UIKit view + UIImage cache; macOS has MacArtworkCache.swift',
  'Shared/UI/Components/AnalysisLookup.swift' => 'SwiftUI view helper for the iOS surface',
  # Tokens.swift uses UIColor, but the real reason is ipad-plan.md §1.6: the
  # tvOS and iOS token sets already disagree (Spacing.md 16 vs 14,
  # CornerRadius vs Radius, different scAccent) and a third silent fork is
  # how a Mac control ends up 2pt off its iPad twin for a year.
  'Shared/Design/Tokens.swift' => 'UIColor; and macOS must not silently fork the design tokens'
}.freeze

# Additional shared files macOS compiles that iOS does not.
SHARED_EXTRA = %w[
  Core/Playback/AudioSessionCoordinator.swift
].freeze

ios_target = project.targets.find { |t| t.name == 'SoundingTV iOS' }
abort "Could not find the 'SoundingTV iOS' target to derive membership from." if ios_target.nil?

swiftpm_prefix = File.join(root, 'SoundingTV.swiftpm', 'Sources') + '/'

derived = ios_target.source_build_phase.files.to_a.map do |bf|
  next nil unless bf.file_ref
  path = bf.file_ref.real_path.to_s
  next nil unless path.start_with?(swiftpm_prefix)
  path.delete_prefix(swiftpm_prefix)
end.compact.sort.uniq

unknown_exclusions = SHARED_EXCLUDE.keys - derived
unless unknown_exclusions.empty?
  # Not fatal — a file can legitimately be dropped from the iOS target — but
  # a stale exclusion is a comment claiming something that is no longer true.
  warn "Exclusions no longer present in the iOS target (stale?): #{unknown_exclusions.join(', ')}"
end

SHARED = (derived - SHARED_EXCLUDE.keys + SHARED_EXTRA).sort.uniq.freeze

puts "Shared files derived from 'SoundingTV iOS': #{derived.count} found, " \
     "#{SHARED_EXCLUDE.size} excluded, #{SHARED_EXTRA.size} macOS-only added " \
     "=> #{SHARED.count}."

# All app-owned Mac sources live below this one root. The shared auth stack is
# already included in SHARED because iOS and macOS now compile the same
# canonical files from SoundingTV.swiftpm/Sources/Auth/Shared.
macos_prefix = File.join(root, 'SoundingTV-macOS', 'Sources') + '/'
MACOS = Dir.glob(File.join(macos_prefix, '**', '*.swift')).map do |path|
  path.delete_prefix(macos_prefix)
end.sort.freeze

# ---------------------------------------------------------------------------

existing = project.targets.find { |t| t.name == TARGET_NAME }
if existing
  warn "Removing existing target #{TARGET_NAME.inspect} before rebuilding it."
  existing.build_phases.each(&:remove_from_project)
  existing.remove_from_project
end

target = project.new_target(:application, TARGET_NAME, :osx, DEPLOYMENT)

# --- Build settings --------------------------------------------------------
#
# Modelled on the `SoundingTV iOS` target, with the platform lines swapped.
# SWIFT_VERSION, MARKETING_VERSION, CURRENT_PROJECT_VERSION and
# DEVELOPMENT_TEAM are inherited from the project level and deliberately not
# repeated.

target.build_configurations.each do |config|
  config.build_settings.merge!(
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon',
    'ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME' => 'AccentColor',
    'CLANG_ENABLE_OBJC_WEAK' => 'NO',
    'CODE_SIGN_ENTITLEMENTS' => 'SoundingTV-macOS/SoundingTV-macOS.entitlements',
    'CODE_SIGN_STYLE' => 'Automatic',
    'COMBINE_HIDPI_IMAGES' => 'YES',
    'ENABLE_HARDENED_RUNTIME' => 'YES',
    'ENABLE_PREVIEWS' => 'YES',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => 'SoundingTV-macOS/Info.plist',
    'LD_RUNPATH_SEARCH_PATHS' => ['$(inherited)', '@executable_path/../Frameworks'],
    'MACOSX_DEPLOYMENT_TARGET' => DEPLOYMENT,
    # CueStore and AnalysisCache link sqlite3 directly, same as iOS/tvOS.
    'OTHER_LDFLAGS' => ['$(inherited)', '-lsqlite3'],
    'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'SDKROOT' => 'macosx',
    'SWIFT_VERSION' => '6.0'
  )
  # A Designed-for-iPad build would set this; a native AppKit-hosted SwiftUI
  # app must not.
  config.build_settings.delete('TARGETED_DEVICE_FAMILY')
  config.build_settings.delete('SUPPORTS_MACCATALYST')
end

# --- File references -------------------------------------------------------
#
# Groups are resolved by their **resolved absolute directory**, not by
# `find_subpath`. This project's group tree does not mirror its directory
# tree: multiple groups can report `hierarchy_path == "/Sources"`, and
# `find_subpath("SoundingTV.swiftpm/Sources/Core", true)` therefore does
# not find the existing Services group — it silently creates a *new* chain of
# groups hanging off the root, and every file lands at the repo root. That is
# how you get "Build input files cannot be found" for 33 files at once.
#
# Matching on `real_path` is unambiguous and needs no knowledge of how the
# group tree happens to be shaped today.
#
# `new_reference` then takes the **basename** — the group already supplies
# the directory, and the group's `source_tree` is never touched.

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

  # Genuinely new directory (SoundingTV-macOS/Sources). Build the chain by
  # hand off the main group so each level carries only its own path
  # component, which is what keeps `real_path` correct for everything
  # underneath it.
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
MACOS.each do |f|
  refs << reference(project, root, "SoundingTV-macOS/Sources/#{File.dirname(f)}", File.basename(f))
end

target.add_file_references(refs)

# --- The seam file must also join tvOS and iOS ------------------------------
#
# `Services/AudioSessionCoordinator.swift` is not optional for the existing
# targets. `PlayerService` and `MixEngine` both call
# `PlatformAudioSession.activatePlayback()` now, so a tvOS or iOS build
# without this file fails to compile — and adding the macOS target without
# adding this file to the other two would leave the tree in a state where
# only the new target builds.
#
# It is therefore done here rather than in a separate step, because the two
# changes are not independently applicable.

seam_ref = reference(project, root, 'SoundingTV.swiftpm/Sources/Core/Playback', 'AudioSessionCoordinator.swift')

['SoundingTV', 'SoundingTV iOS'].each do |name|
  t = project.targets.find { |x| x.name == name }
  abort "Could not find target #{name.inspect}." if t.nil?
  already = t.source_build_phase.files.any? { |bf| bf.file_ref == seam_ref }
  next if already
  t.add_file_references([seam_ref])
  puts "Added AudioSessionCoordinator.swift to #{name}."
end

# --- Sanity checks ---------------------------------------------------------
#
# Fail loudly rather than produce a target that builds nothing. A missing
# source file here means the membership list above has drifted from the tree.

missing = target.source_build_phase.files.map { |bf| bf.file_ref.real_path.to_s }
                .reject { |p| File.exist?(p) }
unless missing.empty?
  abort "Missing source files:\n  #{missing.join("\n  ")}"
end

%w[SoundingTV-macOS/Info.plist SoundingTV-macOS/SoundingTV-macOS.entitlements].each do |p|
  abort "Missing #{p}" unless File.exist?(File.join(root, p))
end

project.save

# --- Scheme ----------------------------------------------------------------
#
# Written after save so it points at a target that exists on disk. Shared, so
# it is checked in alongside the other five.

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(PROJECT_PATH, TARGET_NAME, true)

puts "Added #{TARGET_NAME}: #{target.source_build_phase.files.count} source files."
puts "Build with:"
puts "  xcodebuild -project #{File.basename(PROJECT_PATH)} -scheme '#{TARGET_NAME}' \\"
puts "    -destination 'platform=macOS,arch=arm64' build"
