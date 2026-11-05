# Recette Homebrew de VidSniper (tap hébergé dans le dépôt de l'app).
# Mise à jour par scripts/release.sh (version et sha256).
#   brew tap elliot67/vidsniper https://github.com/Elliot67/VidSniper
#   brew install --cask vidsniper
cask "vidsniper" do
  version "0.1.0"
  sha256 "f8713a598f444d62d9f05754fb05f92ec78d093e7eda131576b75f743274701d"

  url "https://github.com/Elliot67/VidSniper/releases/download/v#{version}/VidSniper-#{version}.zip"
  name "VidSniper"
  desc "Record part of the screen, trim it and share the video"
  homepage "https://github.com/Elliot67/VidSniper"

  depends_on macos: :sequoia

  app "VidSniper.app"

  # L'app n'est pas notarisée (pas de compte Apple Developer payant) : on retire la quarantaine
  # pour que macOS ne bloque pas le premier lancement. Étapes déclaratives (Homebrew 7 et plus) :
  # {{appdir}} est remplacé par le dossier d'installation au moment de l'installation.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/VidSniper.app"]
  end

  zap trash: [
    "~/Library/Caches/VidSniper",
    "~/Library/Preferences/com.elintz.VidSniper.plist",
  ]
end
