# typed: false
# frozen_string_literal: true

class Raptor < Formula
  desc "Keyboard-driven Rex session and project launcher with a native Mac picker"
  homepage "https://github.com/alienxp03/raptor"
  license "MIT"
  head "https://github.com/alienxp03/raptor.git", branch: "master"

  if build.head?
    depends_on xcode: ["26.0", :build]
  end
  depends_on macos: :sonoma
  depends_on "zoxide"
  depends_on "fd"
  depends_on "worktrunk"
  depends_on "gh"

  def install
    if build.stable?
      # Homebrew stages url downloads as bare files in HOMEBREW_CACHE;
      # unzip the release archive into the buildpath ourselves.
      patterns = [
        HOMEBREW_CACHE.join("downloads/*raptor-#{version}-universal.zip"),
        HOMEBREW_CACHE.join("*raptor-#{version}-universal.zip"),
        HOMEBREW_CACHE.join("raptor--#{version}.zip"),
      ]
      zips = patterns.flat_map { |pattern| Dir.glob(pattern) }
      raise "release archive for #{version} not found in HOMEBREW_CACHE" if zips.empty?
      system "unzip", "-q", zips.first, "-d", buildpath
      # The resh model ships a bare host/CLI binary and the Rex plugin.
      bin.install buildpath/"raptor"
      pkgshare.install buildpath/"init.lua"
      return
    end

    ENV["VERSION"] = "0.0.1"
    ENV["DIST_DIR"] = buildpath/"dist"

    arch = Hardware::CPU.arm? ? "arm64" : "x86_64"
    system "bash", "scripts/build-macos.sh", "--arch", arch

    bin.install "dist/raptor"
    pkgshare.install "dist/init.lua"
  end

  def caveats
    <<~EOS
      For a HEAD install, add --fetch-HEAD.

      The host binary is ad-hoc signed when built from source; release
      archives carry a stable signature. The formula does not remove
      quarantine flags or change macOS security settings.
      A manual CLI earlier on PATH (such as ~/.local/bin/raptor) shadows
      this package's CLI; remove it to use the managed one.

      CLI: #{opt_bin}/raptor
      Rex plugin: #{opt_pkgshare}/init.lua

      The native picker runs as a bare host process spawned under Rex
      (raptor serve), so it inherits Rex's file-access grants: no TCC
      prompts for the fd directory scan. Quit it before upgrading:
        pkill -f 'raptor serve'

      Rex, Git, and your key bindings remain external.
      Existing Rex config and plugin checkouts are not overwritten.

      For a fresh Rex setup, run:
        raptor init
        rex config reload

      That writes one managed block (plugin, setup, bindings) between
      `-- >>> raptor >>>` markers; rerun any time to refresh it. The block
      loads the plugin with dofile from this stable opt path — no Lua
      search-path edits, resh-style. shift+cmd+n needs the raptor_worktree_new
      action; remove that bind line if you do not want it.

      A config that already wires raptor outside the managed block is left
      alone; rerun with --force after removing the old lines.
    EOS
  end

  test do
    # HEAD builds bake their commit suffix; stable bakes the version.
    assert_match(/^(#{Regexp.escape(version.to_s)}|HEAD-)/, shell_output("#{bin}/raptor version"))
    assert_predicate pkgshare/"init.lua", :file?
    assert_match "unknown method", pipe_output("#{bin}/raptor api",
                                               %Q({"id":1,"method":"__package_test__","params":{}}\n))
  end
end
