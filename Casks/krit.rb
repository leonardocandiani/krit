cask "krit" do
  version "0.17.1"

  # Digest of the published DMG; release.sh prints it ("DMG sha256:") for each
  # release. Update version and sha256 together, never one without the other.
  sha256 "e3d516661241191b088a2962dcbc2213aa057c1e8dc850c3bb5cee5bc0b69fab"

  # The artifact name MUST match what app/make-dmg.sh produces
  # (KRIT-v#{version}-macOS.dmg). Any mismatch breaks cask installation.
  url "https://github.com/leonardocandiani/krit/releases/download/v#{version}/KRIT-v#{version}-macOS.dmg"

  name "KRIT"
  desc "Native screenshot and markup for macOS"
  homepage "https://github.com/leonardocandiani/krit"

  # Requires macOS 13 (Ventura), aligned with LSMinimumSystemVersion in Info.plist.
  depends_on macos: ">= :ventura"

  app "KRIT.app"

  # KRIT is ad-hoc signed, not notarized, so macOS quarantines the download.
  # Strip the quarantine flag after install so the app launches without a
  # Gatekeeper block. Remove this once the DMG is notarized.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-rd", "com.apple.quarantine", "#{appdir}/KRIT.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.krit.app.plist",
    "~/Library/Caches/com.krit.app",
    "~/Library/Application Support/KRIT",
  ]

  caveats <<~EOS
    KRIT is not signed with an Apple Developer ID certificate or notarized.
    If macOS blocks the app on first launch, run:
      xattr -rd com.apple.quarantine /Applications/KRIT.app

    On first launch, grant Screen Recording permission when prompted
    (System Settings -> Privacy & Security -> Screen Recording).
  EOS
end
