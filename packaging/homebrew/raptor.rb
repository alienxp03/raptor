# typed: false
# frozen_string_literal: true

class Raptor < Formula
  desc "Keyboard-driven Rex picker with native Mac and terminal interfaces"
  homepage "https://github.com/alienxp03/raptor"
  license :cannot_represent
  head "https://github.com/alienxp03/raptor.git", branch: "master"

  if build.head?
    depends_on "go" => :build
    depends_on xcode: ["26.0", :build]
  end
  depends_on macos: :sonoma
  depends_on "zoxide"
  depends_on "worktrunk"
  depends_on "gh"

  def setup_go_environment
    ENV["GOENV"] = "off"
    ENV["GOWORK"] = "off"
    ENV["GOTOOLCHAIN"] = "local"
    ENV["GOFLAGS"] = "-mod=readonly"
    ENV["GOMODCACHE"] = HOMEBREW_CACHE/"go_mod_cache/pkg/mod"
    ENV["GOCACHE"] = buildpath/".go-build-cache"
  end

  def fetch
    return unless build.head?

    setup_go_environment
    system formula_opt_bin("go")/"go", "mod", "download"
  end

  def install
    if build.stable?
      libexec.install "Raptor.app"
      bin.install_symlink libexec/"Raptor.app/Contents/MacOS/raptor-cli" => "raptor"
      pkgshare.install libexec/"Raptor.app/Contents/Resources/rex/init.lua"
      return
    end

    setup_go_environment
    ENV["GOPROXY"] = "off"
    ENV["GOSUMDB"] = "off"
    ENV["GO"] = formula_opt_bin("go")/"go"
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
      Stable archive downloads must be publicly accessible.
      Private HEAD builds need repository read access; see the README.

      App: #{opt_libexec}/Raptor.app
      CLI: #{opt_bin}/raptor
      Rex plugin: #{opt_share}/raptor/init.lua

      Rex, Git, and your key bindings remain external.
      Existing Rex config, plugin checkouts, and local apps are not overwritten.

      For a fresh Rex setup, append this to ~/.config/rex/init.lua:
        package.path = package.path .. ";#{opt_share}/?/init.lua"
        require("raptor").setup{}
        rex.bind("shift+cmd+o", "raptor")
        rex.bind("shift+cmd+t", "raptor_worktree_list")
        rex.bind("ctrl+n", "raptor_worktree_new")

      Then run: rex config reload
      An existing plugin checkout must be updated to use automatic Homebrew discovery.
      A manual ~/.local/bin/raptor can shadow Homebrew's CLI on PATH.
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
