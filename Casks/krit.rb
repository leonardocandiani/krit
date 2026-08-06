cask "krit" do
  version "0.31.2"

  # Digest of the published DMG; release.sh prints it ("DMG sha256:") for each
  # release. Update version and sha256 together, never one without the other.
  sha256 "5c089ddff57af189e66c848a14826a6792ac479322314295456128882f35dc5b"

  # The artifact name MUST match what app/make-dmg.sh produces
  # (KRIT-v#{version}-macOS.dmg). Any mismatch breaks cask installation.
  url "https://github.com/leonardocandiani/krit/releases/download/v#{version}/KRIT-v#{version}-macOS.dmg"

  name "KRIT"
  desc "Native screenshot and markup for macOS"
  homepage "https://github.com/leonardocandiani/krit"

  # Requires macOS 13 (Ventura), aligned with LSMinimumSystemVersion in Info.plist.
  depends_on macos: ">= :ventura"

  app "KRIT.app"

  postflight do
    signature_policy = <<~EOS
      /usr/bin/codesign --verify --deep --strict "$1" || exit 1
      signature=$(/usr/bin/codesign -dv --verbose=4 "$1" 2>&1)
      case "$signature" in
        *"Signature=adhoc"*)
          /usr/bin/xattr -rd com.apple.quarantine "$1" 2>/dev/null || true
          if /usr/bin/xattr -r "$1" 2>/dev/null | /usr/bin/grep -Fq com.apple.quarantine; then
            echo "Could not remove Gatekeeper quarantine from KRIT.app." >&2
            exit 1
          fi
          ;;
        *"Authority=Developer ID Application:"*) ;;
        *) echo "KRIT.app has an unsupported code signature." >&2; exit 1 ;;
      esac
    EOS
    system_command "/bin/sh",
                   args: ["-c", signature_policy, "krit-postflight", "#{appdir}/KRIT.app"]
  end

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
