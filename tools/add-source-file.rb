#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Adds one or more Swift files to SoundingTV.xcodeproj, mirroring the target
# membership of an existing file.
#
#     ruby tools/add-source-file.rb NEW --like EXISTING [NEW2 NEW3 ...]
#
# Paths are relative to the repo root. Example — a type extracted out of
# DownloadManager.swift belongs to exactly the targets DownloadManager.swift
# is already in:
#
#     ruby tools/add-source-file.rb \
#       SoundingTV.swiftpm/Sources/Core/Downloads/DownloadBudgetPolicy.swift \
#       --like SoundingTV.swiftpm/Sources/Core/Downloads/DownloadManager.swift
#
# Idempotent: a file already in a target is left alone.
#
# This exists because `project.pbxproj` is hand-maintained here and is a
# serialization bottleneck (see tools/add-macos-target.rb). Extracting a type
# into a new file is only half the change — without matching target
# membership the build fails with a confusing "cannot find X in scope" in an
# unrelated file.
#
# Obeys the same xcodeproj-gem rule as the other scripts: anchor a file by its
# group's resolved absolute directory, pass the *basename* as the reference
# path, and never touch a group's `source_tree`.

require 'xcodeproj'
require 'pathname'

args = ARGV.dup
like_index = args.index('--like')
targets_index = args.index('--targets')

if like_index.nil? && targets_index.nil?
  abort "Usage: #{File.basename($PROGRAM_NAME)} NEW... (--like EXISTING | --targets 'A,B')"
end

reference_rel = nil
explicit_targets = nil

if like_index
  reference_rel = args[like_index + 1]
  abort 'Missing path after --like' if reference_rel.nil?
  args.delete_at(like_index + 1)
  args.delete_at(like_index)
  targets_index = args.index('--targets')
end

if targets_index
  raw = args[targets_index + 1]
  abort 'Missing value after --targets' if raw.nil?
  explicit_targets = raw.split(',').map(&:strip)
  args.delete_at(targets_index + 1)
  args.delete_at(targets_index)
end

new_rels = args
abort 'No new files given.' if new_rels.empty?

PROJECT_PATH = File.expand_path('../SoundingTV.xcodeproj', __dir__)
ROOT = File.dirname(PROJECT_PATH)

project = Xcodeproj::Project.open(PROJECT_PATH)

reference_targets =
  if explicit_targets
    found = project.targets.select { |t| explicit_targets.include?(t.name) }
    missing = explicit_targets - found.map(&:name)
    abort "Unknown target(s): #{missing.join(', ')}" unless missing.empty?
    found
  else
    reference_abs = Pathname.new(File.join(ROOT, reference_rel)).cleanpath
    project.targets.select do |target|
      target.source_build_phase.files.any? do |bf|
        bf.file_ref && (bf.file_ref.real_path.cleanpath rescue nil) == reference_abs
      end
    end
  end

if reference_targets.empty?
  abort "Reference file is in no target: #{reference_rel}"
end
puts "Target membership: #{reference_targets.map(&:name).join(', ')}"

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

changed = false

new_rels.each do |rel|
  abs = File.join(ROOT, rel)
  abort "Missing file: #{rel}" unless File.exist?(abs)

  group = group_for_directory(project, ROOT, File.dirname(rel))
  basename = File.basename(rel)
  ref = group.files.find { |f| f.path == basename } || group.new_reference(basename)

  reference_targets.each do |target|
    already = target.source_build_phase.files.any? { |bf| bf.file_ref == ref }
    if already
      puts "  #{basename} already in #{target.name}"
      next
    end
    target.add_file_references([ref])
    changed = true
    puts "  added #{basename} to #{target.name}"
  end
end

if changed
  project.save
  puts 'Saved.'
else
  puts 'Nothing to do.'
end
