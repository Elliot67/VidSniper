# Recette Homebrew de VidSniper (tap hébergé dans le dépôt de l'app).
# Mise à jour par scripts/release.sh (version et sha256).
#   brew tap elliot67/vidsniper https://github.com/Elliot67/VidSniper
#   brew install --cask vidsniper
cask "vidsniper" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/Elliot67/VidSniper/releases/download/v#{version}/VidSniper-#{version}.zip"
  name "VidSniper"
  desc "Enregistre une zone de l'écran, coupe et partage la vidéo"
  homepage "https://github.com/Elliot67/VidSniper"

  depends_on macos: ">= :sequoia"

  app "VidSniper.app"

  # L'app n'est pas notarisée (pas de compte Apple Developer payant) : on retire la quarantaine
  # pour que macOS ne bloque pas le premier lancement.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/VidSniper.app"]
  end

  zap trash: [
    "~/Library/Caches/VidSniper",
    "~/Library/Preferences/com.elintz.VidSniper.plist",
  ]
end
