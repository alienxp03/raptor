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
      libexec.install "Raptor.app"
      bin.install_symlink libexec/"Raptor.app/Contents/MacOS/raptor-cli" => "raptor"
      pkgshare.install libexec/"Raptor.app/Contents/Resources/rex/init.lua"
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
    assert_match(build.head? ? "HEAD" : version.to_s, shell_output("#{bin}/raptor version"))
    assert_predicate pkgshare/"init.lua", :file?
    system "/usr/bin/plutil", "-lint", libexec/"Raptor.app/Contents/Info.plist"
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", libexec/"Raptor.app"

    response = JSON.parse(pipe_output("#{bin}/raptor api",
                                     %Q({"id":1,"method":"__package_test__","params":{}}\n), 0))
    assert_equal 1, response["id"]
    assert_match "unknown method", response["error"]
  end
end
