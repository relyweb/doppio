cask "doppio" do
  version "0.0.1"
  sha256 "466861d997442e9d92fb6aab0d62b3ff6d40e064a59a0a40a6d2e4450e151fdf"

  url "https://github.com/relyweb/doppio/releases/download/v#{version}/Doppio.zip",
      verified: "github.com/relyweb/doppio/"
  name "Doppio"
  desc "Prevents sleep for Claude Code, omp, and other agentic tasks"
  homepage "https://github.com/relyweb/doppio"

  depends_on macos: :ventura

  app "Doppio.app"

  # The app is ad-hoc signed (not notarized). Gatekeeper quarantines downloaded
  # unsigned apps, so strip the flag on install; otherwise the first launch is
  # blocked until the user approves it under System Settings > Privacy & Security.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Doppio.app"],
                   sudo: false
  end

  uninstall quit: "com.doppio.keepawake"

  zap trash: "~/Library/Preferences/com.doppio.keepawake.plist"
end
