cask "krit" do
  version "0.28.1"

  # Digest of the published DMG; release.sh prints it ("DMG sha256:") for each
  # release. Update version and sha256 together, never one without the other.
  sha256 "7dd3ac8f109f6d95071e29cffa508543e22429ee8aa1af9f90a7d90908eacdaa"

  # The artifact name MUST match what app/make-dmg.sh produces
  # (KRIT-v#{version}-macOS.dmg). Any mismatch breaks cask installation.
  url "https://github.com/leonardocandiani/krit/releases/download/v#{version}/KRIT-v#{version}-macOS.dmg"

  name "KRIT"
  desc "Native screenshot and markup for macOS"
  homepage "https://github.com/leonardocandiani/krit"

  # Requires macOS 13 (Ventura), aligned with LSMinimumSystemVersion in Info.plist.
  depends_on macos: ">= :ventura"

  app "KRIT.app"

  zap trash: [
    "~/Library/Preferences/com.krit.app.plist",
    "~/Library/Caches/com.krit.app",
    "~/Library/Application Support/KRIT",
  ]

  caveats <<~EOS
    On first launch, grant Screen Recording permission when prompted
    (System Settings -> Privacy & Security -> Screen Recording).
  EOS
end
