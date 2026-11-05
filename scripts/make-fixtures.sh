#!/bin/zsh
# Génère les vidéos de test dans build/fixtures (non versionnées, ~1 s). Demande ffmpeg (brew install ffmpeg).
# Le vrai enregistrement de référence, lui, est versionné : VidSniperTests/Fixtures/reference.mov.
#
#   recording.mov  comme un enregistrement VidSniper : HEVC, 60 i/s, 3 s, mire de couleurs SMPTE étiquetée
#                  comme l'app (BT.709, courbe sRGB) + compteur d'images qui bouge, deux pistes audio
#                  (son système 440 Hz, micro 880 Hz)
#   imported.mp4   vidéo importée minimale : H.264 sans étiquette de couleur, une piste audio, 2 s
set -euo pipefail

cd "$(dirname "$0")/.."
out="build/fixtures"
mkdir -p "$out"
# Cache des polices du compteur d'images (sinon fontconfig se plaint de ne pas pouvoir l'écrire).
export XDG_CACHE_HOME="${TMPDIR:-/tmp}"

if ! command -v ffmpeg >/dev/null; then
    echo "ffmpeg introuvable : brew install ffmpeg" >&2
    exit 1
fi

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "smptehdbars=size=1280x720:rate=60:duration=3" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=3" \
    -f lavfi -i "sine=frequency=880:sample_rate=48000:duration=3" \
    -filter_complex "[0:v]drawtext=text='%{frame_num}':x=40:y=40:fontsize=64:fontcolor=white:box=1:boxcolor=black[v]" \
    -map "[v]" -map 1:a -map 2:a \
    -c:v libx265 -tag:v hvc1 -pix_fmt yuv420p \
    -x265-params "log-level=error:colorprim=bt709:transfer=iec61966-2-1:colormatrix=bt709" \
    -color_primaries bt709 -color_trc iec61966-2-1 -colorspace bt709 \
    -c:a aac -b:a 128k \
    "$out/recording.mov"

ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=640x360:rate=30:duration=2" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
    -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 128k \
    "$out/imported.mp4"

echo "Vidéos de test : $out"
