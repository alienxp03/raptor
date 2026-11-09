#!/usr/bin/env ruby
# Generate the stable formula only after the archive exists. Never edit the tap.
require "digest"

version, directory = ARGV
abort "Usage: ruby scripts/release-formula.rb VERSION ARCHIVE_DIRECTORY" unless
  ARGV.length == 2 && version.match?(/\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/)

archive = File.join(directory, "Raptor-#{version}-universal.zip")
abort "Missing archive: #{archive}" unless File.file?(archive)
checksum = Digest::SHA256.file(archive).hexdigest
formula = File.read(File.expand_path("../packaging/homebrew/raptor.rb", __dir__))
anchor = "  license :cannot_represent\n"
abort "Expected one license declaration" unless formula.scan(anchor).length == 1
stable = <<~RUBY

    url "https://github.com/alienxp03/raptor/releases/download/v#{version}/Raptor-#{version}-universal.zip"
    sha256 "#{checksum}"
    version "#{version}"
RUBY
print formula.sub(anchor, anchor + stable.lines.map { |line| line.strip.empty? ? line : "  #{line}" }.join)
