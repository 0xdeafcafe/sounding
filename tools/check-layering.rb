#!/usr/bin/env ruby
# frozen_string_literal: true

# Fast static integrity check for source-tree layering and Xcode target
# membership, without invoking a build. See Design/notes/source-tree.md.

require 'pathname'
require 'set'
require 'xcodeproj'

ROOT = Pathname.new(__dir__).join('..').expand_path
PROJECT_PATH = ROOT.join('SoundingTV.xcodeproj')
QUIET = ARGV.delete('--quiet')
abort "Usage: #{File.basename($PROGRAM_NAME)} [--quiet]" unless ARGV.empty?

LAYERS = [
  { layer: 0, name: 'Core', path: ROOT.join('SoundingTV.swiftpm/Sources/Core') },
  { layer: 0, name: 'Auth/Shared', path: ROOT.join('SoundingTV.swiftpm/Sources/Auth/Shared') },
  { layer: 1, name: 'Shared', path: ROOT.join('SoundingTV.swiftpm/Sources/Shared') },
  { layer: 2, name: 'Apps/tvOS', path: ROOT.join('SoundingTV.swiftpm/Sources/Apps/tvOS'), owner: 'SoundingTV' },
  { layer: 2, name: 'SoundingTV-iOS', path: ROOT.join('SoundingTV-iOS/Sources'), owner: 'SoundingTV iOS' },
  { layer: 2, name: 'SoundingTV-macOS', path: ROOT.join('SoundingTV-macOS/Sources'), owner: 'SoundingTV macOS' },
  { layer: 2, name: 'SoundingTV-Share', path: ROOT.join('SoundingTV-Share/Sources'), owner: 'SoundingTV-Share' },
  { layer: 2, name: 'SoundingTV-TopShelf', path: ROOT.join('SoundingTV-TopShelf/Sources'), owner: 'SoundingTV-TopShelf' },
  { layer: 2, name: 'SoundingTV-UITests', path: ROOT.join('SoundingTV-UITests/Sources'), owner: 'SoundingTV-UITests' }
].freeze

DECLARATION = /
  \A
  ((?:(?:public|private|fileprivate|internal|open|final|indirect|package|@\w+(?:\([^)]*\))?)\s+)*)
  (?:class|struct|enum|actor|protocol|typealias)\s+
  ([A-Za-z_]\w*)
/x
FILE_SCOPED_MODIFIER = /\b(?:private|fileprivate)\b/.freeze

IDENTIFIER = /[A-Za-z_]\w*/.freeze

COMPILED_EXTENSIONS = %w[.swift .metal .m .mm .c .cpp].freeze

# Known file-level dependency cycles.
#
# Everything under SoundingTV.swiftpm/Sources compiles into a single Swift
# module (per app target), so a reference cycle between two files never
# fails to build — nothing about the language enforces acyclic files the
# way it enforces acyclic *modules*. These tangles only became visible when
# a narrower target (a watchOS extension compiling a subset of Core) tried
# to pull in less than the whole pile and couldn't, because half of "less
# than the whole pile" turned out to still need the other half.
#
# Every entry below is DEBT TO BE PAID DOWN, not an approved pattern. Never
# add an entry to make a *new* cycle pass — untangle the files instead. Only
# add here when deliberately absorbing a pre-existing tangle you are not
# fixing right now, and remove an entry the moment its cycle is actually
# broken (the check will tell you, via the stale-allowlist note, when one
# still lists files that no longer cycle).
#
# Each entry is the sorted set of files making up one strongly connected
# component.
#
# All known cycles were paid down in the 2026-08 cleanup pass:
# - AnalysisCache <-> AnalysisSync was broken by moving the self-test out of
#   AnalysisSync.swift into AnalysisSyncSelfTest.swift.
# - The DJ five-file cycle was broken by extracting DJTypes.swift/DJEngineConstants
#   so the rest of the DJ layer depends one-way on the base types.
# - CollectionQualityOverrides <-> DownloadManager was broken by introducing
#   the CollectionPolicyApplier protocol.
# - Core/Models <-> SoundCloud was broken by moving APIError and TrackAbout
#   into the model files that needed them.
#
# Keep this list empty unless a new cycle is deliberately absorbed (not fixed)
# for a specific reason.
CYCLE_ALLOWLIST = [
].freeze

def swift_files(path)
  return [] unless path.directory?

  Pathname.glob(path.join('**/*.swift')).sort
end

def compiled_files(path)
  return [] unless path.directory?

  Pathname.glob(path.join("**/*{#{COMPILED_EXTENSIONS.join(',')}}")).sort
end

def blank(match)
  match.gsub(/[^\n]/, ' ')
end

def strip_noise(text)
  text = text.gsub(/"""(?:.|\n)*?"""/m) { |m| blank(m) }
  text = text.gsub(/"(?:\\.|[^"\\\n])*"/) { |m| blank(m) }
  text = text.gsub(%r{/\*.*?\*/}m) { |m| blank(m) }
  text.gsub(%r{//[^\n]*}) { |m| blank(m) }
end

file_lines = {}
file_declared = Hash.new { |h, k| h[k] = Set.new }
symbol_layer_nums = {}
symbol_layer_names = {}
symbol_owners = Hash.new { |h, k| h[k] = Set.new }

LAYERS.each do |layer_info|
  swift_files(layer_info[:path]).each do |file|
    lines = strip_noise(file.read).lines
    file_lines[file] = lines
    lines.each do |line|
      # DECLARATION is anchored with \A against a single, un-stripped line,
      # so it only ever matches a declaration sitting at column 0 — an
      # indented (nested) `struct State` inside some class never reaches
      # this branch. That's what keeps file_declared/symbol_owners limited
      # to genuine top-level symbols; do not "helpfully" .strip lines before
      # matching, or nested names like State/Phase/Credentials/Outcome will
      # start looking like top-level symbols owned by whichever file happens
      # to declare them first, and the cycle check below will start
      # reporting cycles that do not exist.
      m = DECLARATION.match(line)
      next unless m

      modifiers, name = m[1], m[2]
      file_declared[file] << name
      next if FILE_SCOPED_MODIFIER.match?(modifiers)

      (symbol_layer_nums[name] ||= Set.new) << layer_info[:layer]
      (symbol_layer_names[name] ||= Set.new) << layer_info[:name]
      symbol_owners[name] << file
    end
  end
end

violations1 = []
referencing_layers = LAYERS.select { |l| l[:layer] <= 1 }
referencing_layers.each do |layer_info|
  swift_files(layer_info[:path]).each do |file|
    declared_here = file_declared[file]
    file_lines.fetch(file).each_with_index do |line, index|
      line.scan(IDENTIFIER).uniq.each do |token|
        next if declared_here.include?(token)

        layers = symbol_layer_nums[token]
        next unless layers
        next unless layers.min > layer_info[:layer]

        declared_in = symbol_layer_names.fetch(token).to_a.sort.join(', ')
        violations1 << "#{file.relative_path_from(ROOT)}:#{index + 1}  #{token} (declared only in #{declared_in})"
      end
    end
  end
end

project = Xcodeproj::Project.open(PROJECT_PATH)
targets_by_path = Hash.new { |h, k| h[k] = Set.new }
target_names = project.targets.map(&:name)
swift_build_file_count = 0

project.targets.each do |target|
  target.source_build_phase.files.each do |build_file|
    ref = build_file.file_ref
    next unless ref && COMPILED_EXTENSIONS.any? { |ext| ref.path.to_s.end_with?(ext) }

    swift_build_file_count += 1
    targets_by_path[ref.real_path.cleanpath] << target.name
  end
end

dangling = project.files.map do |ref|
  next nil unless COMPILED_EXTENSIONS.any? { |ext| ref.path.to_s.end_with?(ext) }

  path = begin
    ref.real_path.cleanpath
  rescue StandardError
    nil
  end
  next nil if path.nil? || path.exist?

  begin
    path.relative_path_from(ROOT).to_s
  rescue ArgumentError
    path.to_s
  end
end.compact.sort

violations2 = []
owned_layers = LAYERS.select { |l| l[:owner] }

owned_layers.each do |layer_info|
  owner = layer_info[:owner]
  swift_files(layer_info[:path]).each do |file|
    extra = targets_by_path[file] - [owner]
    next if extra.empty?

    violations2 << "#{file.relative_path_from(ROOT)}  compiled into #{extra.to_a.sort.join(', ')} (owned by #{owner})"
  end
end

LAYERS.each do |layer_info|
  compiled_files(layer_info[:path]).each do |file|
    next unless targets_by_path[file].empty?

    violations2 << "#{file.relative_path_from(ROOT)}  not compiled into any target"
  end
end

dangling.each do |path|
  violations2 << "#{path}  referenced by the project but missing on disk"
end

# Check 3: file-level dependency cycles.
#
# A directed edge file A -> file B means "A's source text references a
# top-level symbol that only file B declares". Symbols declared in more
# than one file (same name reused across separate app targets, e.g. two
# platforms each with their own `RootView`) are dropped rather than
# guessed at — an edge we can't attribute unambiguously is worse than no
# edge, since a wrong edge can manufacture a cycle that isn't real.
#
# Edge *sources* are limited to the same layers checked above (layer <= 1:
# Core, Auth/Shared, Shared) — reusing referencing_layers, not LAYERS. This
# is the part of the tree that gets cherry-picked into a narrower target
# (see SHARED_EXCLUDE/SHARED_EXTRA in add-macos-target.rb for a concrete,
# already-real example of that), so it's the part where an internal cycle
# can actually block a subset build. Apps/* (layer 2) is always compiled
# as one monolithic target per platform, never partially, so cross-file
# cycles among e.g. tvOS's own feature views are real edges but not the
# kind of tangle this check exists to catch; scoping edge sources this way
# keeps them out of both the graph's cycles and the allowlist. They can
# still be edge *targets* (owners.size == 1 lookups aren't scope-limited),
# they just can never close a cycle since nothing downstream of them is a
# source.
edges = Hash.new { |h, k| h[k] = Set.new }

referencing_layers.each do |layer_info|
  swift_files(layer_info[:path]).each do |file|
    declared_here = file_declared[file]
    file_lines.fetch(file).each do |line|
      line.scan(IDENTIFIER).uniq.each do |token|
        next if declared_here.include?(token)

        owners = symbol_owners[token]
        next unless owners.size == 1

        owner_file = owners.first
        next if owner_file == file

        edges[file] << owner_file
      end
    end
  end
end

# Tarjan's strongly-connected-components algorithm, iterative call graph,
# recursive implementation (the source tree is a couple hundred files —
# nowhere near deep enough to need an explicit stack).
def strongly_connected_components(edges)
  index = 0
  indices = {}
  lowlinks = {}
  on_stack = {}
  stack = []
  sccs = []

  visit = nil
  visit = lambda do |node|
    indices[node] = index
    lowlinks[node] = index
    index += 1
    stack.push(node)
    on_stack[node] = true

    edges[node].each do |neighbour|
      if indices.key?(neighbour)
        lowlinks[node] = [lowlinks[node], indices[neighbour]].min if on_stack[neighbour]
      else
        visit.call(neighbour)
        lowlinks[node] = [lowlinks[node], lowlinks[neighbour]].min
      end
    end

    next unless lowlinks[node] == indices[node]

    component = []
    loop do
      member = stack.pop
      on_stack[member] = false
      component << member
      break if member == node
    end
    sccs << component
  end

  all_nodes = edges.keys | edges.values.flat_map(&:to_a)
  all_nodes.each { |node| visit.call(node) unless indices.key?(node) }
  sccs
end

found_cycles = strongly_connected_components(edges)
                 .select { |component| component.size > 1 }
                 .map { |component| component.map { |f| f.relative_path_from(ROOT).to_s }.sort }
                 .sort

allowlisted_cycles = CYCLE_ALLOWLIST.map(&:sort)
new_cycles = found_cycles.reject { |cycle| allowlisted_cycles.include?(cycle) }
stale_allowlist_entries = allowlisted_cycles.reject { |cycle| found_cycles.include?(cycle) }

# A ScrollView eagerly instantiates a direct VStack/HStack child. Potentially
# unbounded surfaces must use SwiftUI's lazy containers so large libraries,
# queues, feeds, and search results stay virtualized on every platform.
virtualization_roots = [
  ROOT.join('SoundingTV.swiftpm/Sources'),
  ROOT.join('SoundingTV-iOS/Sources'),
  ROOT.join('SoundingTV-macOS/Sources'),
  ROOT.join('SoundingTV-watchOS/Sources')
]
violations4 = []
violations5 = []
virtualization_roots.flat_map { |root| swift_files(root) }.uniq.sort.each do |file|
  source = strip_noise(file.read)
  source.to_enum(:scan, /ScrollView(?:\s*\([^)]*\))?\s*\{\s*(VStack|HStack)\b/m).each do
    match = Regexp.last_match
    line = source[0...match.begin(1)].count("\n") + 1
    violations4 << "#{file.relative_path_from(ROOT)}:#{line}  eager #{match[1]} directly inside ScrollView"
  end

  relative = file.relative_path_from(ROOT).to_s
  unless relative.start_with?('SoundingTV.swiftpm/Sources/Core/', 'SoundingTV.swiftpm/Sources/Auth/')
    source.to_enum(:scan, /\bwhile\s*(?:\([^)]*)?[^\n{]*nextHref\b/).each do
      match = Regexp.last_match
      line = source[0...match.begin(0)].count("\n") + 1
      violations5 << "#{relative}:#{line}  UI-owned loop eagerly walks pagination"
    end

    source.to_enum(:scan, /\bloadSection\(\s*[^,)\n]+\s*\)/).each do
      match = Regexp.last_match
      line = source[0...match.begin(0)].count("\n") + 1
      violations5 << "#{relative}:#{line}  cache materialization has no explicit limit"
    end

    source.to_enum(:scan, /\bfunc\s+loadRemainingForSearch\b/).each do
      match = Regexp.last_match
      line = source[0...match.begin(0)].count("\n") + 1
      violations5 << "#{relative}:#{line}  local search must not eagerly hydrate every remaining page"
    end
  end
end


# Typed observable state replaces stringly domain broadcasts. Framework and
# platform lifecycle notifications remain valid at adapter boundaries.
forbidden_domain_broadcasts = %w[
  likesIndexDidChange
  trackLikeChanged
  soundCloudAuthenticationChanged
  soundCloudTrafficSafetyChanged
  sessionExpired
  pairedTVDidChange
  companionClientAuthHandoffRequest
  audioOutputRouteDidChange
  presentSoundCloudMessages
]
violations6 = []
violations7 = []
file_lines.each do |file, lines|
  lines.each_with_index do |line, index|
    forbidden_domain_broadcasts.each do |name|
      next unless line.include?(name)

      violations6 << "#{file.relative_path_from(ROOT)}:#{index + 1}  domain broadcast #{name} must be observable typed state"
    end
  end

  relative = file.relative_path_from(ROOT).to_s
  source = strip_noise(file.read)
  if source.match?(/\bNWPathMonitor\b/) && !relative.end_with?('Core/Support/AppRuntime.swift')
    violations7 << "#{relative}  reachability must be owned by RuntimeNetworkIntegration"
  end
  if source.match?(/\b(?:AVPlayer|AVQueuePlayer|AVAudioPlayer|AVAudioEngine|AVAudioPlayerNode)\b/) &&
     !relative.end_with?('Core/Playback/PlayerService.swift', 'Core/DJ/MixEngine.swift')
    violations7 << "#{relative}  audio rendering must be owned by PlayerService/MixEngine"
  end
end

total_symbols = symbol_layer_nums.size
all_swift_files = LAYERS.sum { |l| swift_files(l[:path]).size }

unless violations1.empty?
  puts 'Check 1: layer violations'
  violations1.each { |v| puts "  #{v}" }
  puts
end

unless violations2.empty?
  puts 'Check 2: target membership drift'
  violations2.each { |v| puts "  #{v}" }
  puts
end

unless new_cycles.empty?
  puts 'Check 3: file-level dependency cycles (not on the allowlist)'
  new_cycles.each do |cycle|
    puts "  cycle of #{cycle.size} files"
    cycle.each { |f| puts "    #{f}" }
  end
  puts
end

unless stale_allowlist_entries.empty?
  puts 'check-layering: allowlisted cycle(s) no longer exist (stale entries in CYCLE_ALLOWLIST, safe to delete):'
  stale_allowlist_entries.each { |cycle| puts "  #{cycle.join(', ')}" }
end

unless violations4.empty?
  puts 'Check 4: non-virtualized scroll containers'
  violations4.each { |v| puts "  #{v}" }
  puts
end

unless violations5.empty?
  puts 'Check 5: eager data materialization'
  violations5.each { |v| puts "  #{v}" }
  puts
end

unless violations6.empty?
  puts 'Check 6: stringly domain broadcasts'
  violations6.each { |v| puts "  #{v}" }
  puts
end

unless violations7.empty?
  puts 'Check 7: duplicate runtime integration ownership'
  violations7.each { |v| puts "  #{v}" }
  puts
end

abort "check-layering: #{violations1.size} layer violation(s), #{violations2.size} membership violation(s), " \
      "#{new_cycles.size} new dependency cycle(s), #{violations4.size} UI virtualization violation(s), " \
      "#{violations5.size} data virtualization violation(s), #{violations6.size} domain broadcast violation(s), " \
      "#{violations7.size} integration ownership violation(s)" \
  unless violations1.empty? && violations2.empty? && new_cycles.empty? && violations4.empty? &&
         violations5.empty? && violations6.empty? && violations7.empty?

unless QUIET
  puts "check-layering: clean (#{all_swift_files} source files, #{total_symbols} top-level symbols, " \
       "#{target_names.size} targets, #{swift_build_file_count} build-file memberships, " \
       "#{found_cycles.size} known file cycle(s) allowlisted)"
end
