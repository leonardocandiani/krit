cask "krit" do
  version "0.15.4"

  # BLOQUEADOR DE RELEASE: :no_check desativa a verificação de integridade e NÃO
  # deve ser publicado num tap. Antes de publicar, substitua por
  #   sha256 "<hash real>"
  # usando o valor impresso pelo CI (passo "Print DMG sha256" no release.yml) para
  # o DMG do release correspondente. :no_check só é aceitável em teste local antes
  # do primeiro release publicado (nenhum DMG existe ainda para hashear).
  sha256 :no_check

  # O nome do artefato DEVE corresponder exatamente ao produzido por make-dmg.sh
  # (KRIT-v$VERSION-macOS.dmg). Qualquer divergência quebra a instalação via cask.
  url "https://github.com/leonardocandiani/krit/releases/download/v#{version}/KRIT-v#{version}-macOS.dmg"

  name "KRIT"
  desc "Native screenshot and markup for macOS"
  homepage "https://github.com/leonardocandiani/krit"

  # Requer macOS 13 (Ventura) — alinhado ao LSMinimumSystemVersion do Info.plist.
  depends_on macos: ">= :ventura"

  # AVISO: O cask só funciona sem prompt do Gatekeeper quando a DMG estiver
  # notarizada (G1). Antes disso o usuário recebe "desenvolvedor não identificado".
  # Não adicione auto_updates true aqui — Sparkle (G3) ainda não está integrado.

  app "KRIT.app"

  zap trash: [
    "~/Library/Preferences/com.krit.app.plist",
    "~/Library/Caches/com.krit.app",
    "~/Library/Application Support/KRIT",
  ]
end
