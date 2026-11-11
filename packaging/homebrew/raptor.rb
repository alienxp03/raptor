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
  depends_on "worktrunk"
  depends_on "gh"

  def install
    if build.stable?
      # Homebrew stages url downloads as bare files in HOMEBREW_CACHE;
      # unzip the release archive into the buildpath ourselves.
      patterns = [
        HOMEBREW_CACHE.join("downloads/*Raptor-#{version}-universal.zip"),
        HOMEBREW_CACHE.join("*Raptor-#{version}-universal.zip"),
        HOMEBREW_CACHE.join("raptor--#{version}.zip"),
      ]
      zips = patterns.flat_map { |pattern| Dir.glob(pattern) }
      raise "release archive for #{version} not found in HOMEBREW_CACHE" if zips.empty?
      system "unzip", "-q", zips.first, "-d", buildpath
      # Preserve the sealed bundle byte-for-byte: copy the plugin out with cp
      # (Homebrew's install helpers move, stripping sealed resources).
      app = buildpath/"Raptor.app"
      system "cp", "-p", app/"Contents/Resources/rex/init.lua", buildpath/"init.lua"
      pkgshare.mkpath
      system "cp", "-p", buildpath/"init.lua", pkgshare/"init.lua"
      libexec.install app
      bin.install_symlink libexec/"Raptor.app/Contents/MacOS/raptor-cli" => "raptor"
      return
    end

    ENV["VERSION"] = "0.0.1"
    ENV["CLI_VERSION"] = version.to_s
    ENV["APP_SIGN_IDENTITY"] = "-"
    ENV["RAPTOR_EXTERNAL_SANDBOX"] = "1"
    ENV["DIST_DIR"] = buildpath/"dist"

    arch = Hardware::CPU.arm? ? "arm64" : "x86_64"
    system "bash", "scripts/build-macos.sh", "--arch", arch

    libexec.install "dist/Raptor.app"
    bin.install_symlink libexec/"Raptor.app/Contents/MacOS/raptor-cli" => "raptor"
    pkgshare.install "init.lua"
  end

  def caveats
    <<~EOS
      Quit Raptor before upgrading:
        brew upgrade alienxp03/tap/raptor
      For a HEAD install, add --fetch-HEAD.

      This app is ad-hoc signed, not Apple-notarized. The formula does not
      remove quarantine flags or change macOS security settings.
      A manual CLI earlier on PATH (such as ~/.local/bin/raptor) shadows
      this package's CLI; remove it to use the managed one.

      App: #{opt_libexec}/Raptor.app
      CLI: #{opt_bin}/raptor
      Rex plugin: #{opt_share}/raptor/init.lua

      Rex, Git, and your key bindings remain external.
      Existing Rex config, plugin checkouts, and local apps are not overwritten.

      For a fresh Rex setup, run:
        raptor init
        rex config reload

      That writes one managed block (plugin, setup, bindings) between
      `-- >>> raptor >>>` markers; rerun any time to refresh it. The block
      loads the plugin with dofile from this stable opt path — no Lua
      search-path edits, resh-style. shift+cmd+n needs the raptor_worktree_new
      action; remove that bind line if you do not want it.

      An existing plugin checkout must be updated to use automatic Homebrew discovery.
      The packaged plugin selects its matching CLI/app without relying on PATH.
      A config that already wires raptor outside the managed block is left
      alone; rerun with --force after removing the old lines.
    EOS
  end

  test do
    # HEAD builds bake their commit suffix; stable bakes the version.
    assert_match(/^(#{Regexp.escape(version.to_s)}|HEAD-)/, shell_output("#{bin}/raptor version"))
    assert_predicate pkgshare/"init.lua", :file?
    system "/usr/bin/plutil", "-lint", libexec/"Raptor.app/Contents/Info.plist"
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", libexec/"Raptor.app"
    assert_match "unknown method", response["error"]
  end
end
