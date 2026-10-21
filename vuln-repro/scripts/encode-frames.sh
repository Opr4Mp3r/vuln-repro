#!/usr/bin/env bash
# Encode captured frames into a 1920x1080 H.264 30fps MP4.
# Usage: encode-frames.sh --frames frames/ --out repro.mp4 --fps 2.4709 \
#        [--ext jpg] [--crf 20] [--preset veryfast] [--timestamp] \
#        [--font PATH] [--cards cards/]
# --fps must be the MEASURED frame rate (total frames / wall-clock seconds of
#   the capture, printed by record-vnc.sh). The default 2.4709 is a historical
#   measured value from one host (nominal 2.5); re-measure on each host or
#   playback speed will drift.
# --preset: x264 preset, default veryfast (previews); use "medium" with
#   --crf 18-20 for the final submission encode.
# --timestamp burns pts (h:m:s) into the bottom-left corner, like a wall clock:
#   useful as evidence that long waits are real time, not edited.
# --cards: dir produced by make-cards.py (card PNGs + placement.tsv). The
#   placement timeline mixes `card <png> <seconds>` and `frames <from> <to>`
#   directives (inclusive positions in the sorted frame list, -1 = last).
#   Card durations are exact seconds at the 30 fps output rate, independent
#   of --fps; captured frames keep 1/--fps each. Without --cards behavior is
#   unchanged (whole frames dir, no cards).
# Scaling is aspect-preserving + black letterbox: the guest resolution may
#   differ from 1920x1080 and stretching would distort the evidence.
set -u
set -o pipefail
export LC_ALL=C

frames=""
out=""
fps="2.4709"
ext="jpg"
crf="20"
preset="veryfast"
timestamp=0
font=""
cards=""
usage() {
  echo "usage: $0 --frames <dir> --out <file.mp4> --fps <measured> [--ext jpg|png] [--crf 20] [--preset veryfast] [--timestamp] [--font PATH] [--cards <dir>]" >&2
  exit 2
}
while [ $# -gt 0 ]; do
  case "$1" in
    --frames) frames=${2:?"--frames requires a value"}; shift 2;;
    --out) out=${2:?"--out requires a value"}; shift 2;;
    --fps) fps=${2:?"--fps requires a value"}; shift 2;;
    --ext) ext=${2:?"--ext requires a value"}; shift 2;;
    --crf) crf=${2:?"--crf requires a value"}; shift 2;;
    --preset) preset=${2:?"--preset requires a value"}; shift 2;;
    --font) font=${2:?"--font requires a value"}; shift 2;;
    --cards) cards=${2:?"--cards requires a value"}; shift 2;;
    --timestamp) timestamp=1; shift;;
    -h|--help) usage;;
    *) echo "unknown arg: $1" >&2; usage;;
  esac
done
[ -n "$frames" ] && [ -n "$out" ] || usage
[ -d "$frames" ] || { echo "FAIL: frames dir not found: $frames" >&2; exit 2; }
ls "$frames"/frame-*.$ext >/dev/null 2>&1 || { echo "FAIL: no frame-*.$ext in $frames" >&2; exit 2; }
[ -z "$cards" ] || [ -f "$cards/placement.tsv" ] || {
  echo "FAIL: $cards/placement.tsv not found (run make-cards.py first)" >&2; exit 2; }
# the concat timeline lists absolute paths: ffmpeg's concat demuxer resolves
# relative `file` entries against the LIST file's dir (a mktemp dir), not cwd
case "$frames" in /*) ;; *) frames=$PWD/$frames;; esac
if [ -n "$cards" ]; then case "$cards" in /*) ;; *) cards=$PWD/$cards;; esac; fi
case "$fps" in *[!0-9.]*) echo "FAIL: --fps must be a number" >&2; exit 2;; esac
awk -v f="$fps" 'BEGIN{exit !(f>0)}' || { echo "FAIL: --fps must be > 0" >&2; exit 2; }

# font candidates cover Debian/Ubuntu (truetype/dejavu) and RHEL/Fedora (dejavu) layouts
if [ -z "$font" ]; then
  for c in /usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf /usr/share/fonts/dejavu/DejaVuSans-Bold.ttf; do
    [ -r "$c" ] && font=$c && break
  done
fi

ffmpeg_bin=/usr/bin/ffmpeg
[ -x "$ffmpeg_bin" ] || ffmpeg_bin=$(command -v ffmpeg) || { echo "FAIL: ffmpeg not found" >&2; exit 2; }
"$ffmpeg_bin" -hide_banner -encoders 2>/dev/null | grep -q libx264 || {
  echo "FAIL: ffmpeg has no libx264; use a build with libx264" >&2; exit 2;
}

scale_vf="scale=1920:1080:force_original_aspect_ratio=decrease:flags=lanczos,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black"
drawtext_vf=""
if [ "$timestamp" -eq 1 ]; then
  if ! "$ffmpeg_bin" -hide_banner -filters 2>/dev/null | grep -q drawtext; then
    echo "WARN: this ffmpeg build has no drawtext filter (needs libfreetype); skipping timestamp overlay" >&2
  elif [ -n "$font" ] && [ -r "$font" ]; then
    drawtext_vf=",drawtext=fontfile=${font}:text='%{pts\:hms}':x=10:y=h-44:fontsize=30:fontcolor=white:box=1:boxcolor=black@0.65"
  else
    echo "WARN: no usable bold font found (tried Debian/RHEL dejavu paths); pass --font <path-to-ttf> to get the timestamp overlay" >&2
  fi
fi

emit_entry() { # emit_entry <path> <duration>; guards quote-in-path
  case "$1" in
    *\'*) echo "FAIL: path contains a single quote, ffmpeg concat cannot express it: $1" >&2; exit 2;;
  esac
  printf "file '%s'\nduration %s\n" "$1" "$2"
}

if [ -n "$cards" ]; then
  # Timeline via the concat demuxer: exact card seconds + 1/fps per frame.
  # The concat demuxer picks ONE demuxer from the first entry, so every entry
  # must share the frames' format: cards are re-encoded to .$ext in a temp dir.
  list=$(mktemp -t encards.XXXXXX) || exit 2
  cext_dir=$(mktemp -d -t encardimg.XXXXXX) || exit 2
  trap 'rm -f "$list"; rm -rf "$cext_dir"' EXIT
  frame_dur=$(awk -v f="$fps" 'BEGIN{printf "%.6f", 1/f}')
  all_frames=()
  for f in "$frames"/frame-*."$ext"; do all_frames+=("$f"); done
  n=${#all_frames[@]}
  [ "$n" -gt 0 ] || { echo "FAIL: no frames in $frames" >&2; exit 2; }
  # Cards must match the frames EXACTLY in size, pix_fmt and SAR: mismatches
  # through the concat demuxer reorder and drop frames (verified empirically;
  # e.g. a 444-chroma card before 420 frames pushes the card to the end).
  if command -v ffprobe >/dev/null 2>&1; then
    fprobe=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt -of csv=p=0 "${all_frames[0]}" 2>/dev/null | head -1 | tr ',' ' ')
  else
    fprobe=$("$ffmpeg_bin" -i "${all_frames[0]}" 2>&1 | sed -n 's/.*, \([0-9]*\)x\([0-9]*\)\[.*/\1 \2/p' | head -1)
    fprobe=${fprobe:-$("$ffmpeg_bin" -i "${all_frames[0]}" 2>&1 | sed -n 's/.*, \([0-9]*\)x\([0-9]*\) .*/\1 \2/p' | head -1)}
  fi
  fw=$(echo "$fprobe" | awk '{print $1}'); fh=$(echo "$fprobe" | awk '{print $2}'); fpix=$(echo "$fprobe" | awk '{print $3}')
  case "$fw$fh" in *[!0-9]*|'') echo "FAIL: cannot probe frame size (got '$fprobe')" >&2; exit 2;; esac
  [ "$fw" -gt 0 ] && [ "$fh" -gt 0 ] || { echo "FAIL: bad frame size ${fw}x${fh}" >&2; exit 2; }
  cardfmt=""
  [ -n "$fpix" ] && cardfmt=",format=${fpix}"
  echo "cards will be re-encoded to ${fw}x${fh} ${fpix:-?} to match captured frames"
  last=""
  total=0
  {
    while IFS=$'\t' read -r d a b; do
      case "$d" in ''|'#'*) continue;; esac
      case "$d" in
        card)
          png=$cards/$a
          [ -f "$png" ] || { echo "FAIL: card not found: $png" >&2; exit 2; }
          awk -v s="$b" 'BEGIN{exit !(s>0)}' || { echo "FAIL: card $a: seconds must be > 0" >&2; exit 2; }
          cbasename=$(basename "$a"); cbasename=${cbasename%.*}
          cimg=$cext_dir/${cbasename}.$ext
          if [ ! -f "$cimg" ]; then
            "$ffmpeg_bin" -y -loglevel error -i "$png" -frames:v 1 \
              -vf "scale=${fw}:${fh}:force_original_aspect_ratio=decrease:flags=lanczos,pad=${fw}:${fh}:(ow-iw)/2:(oh-ih)/2:black,setsar=1${cardfmt}" \
              -q:v 2 "$cimg" || {
              echo "FAIL: card re-encode to ${fw}x${fh} failed: $a" >&2; exit 2; }
            # verify the converted card matches the frames: mismatched size or
            # pix_fmt silently breaks concat ordering (see comment above)
            if command -v ffprobe >/dev/null 2>&1; then
              cprobe=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height,pix_fmt -of csv=p=0 "$cimg" 2>/dev/null | head -1 | tr ',' ' ')
              [ "$cprobe" = "$fprobe" ] || {
                echo "FAIL: card '$a' probe '$cprobe' != frames '$fprobe' after re-encode; concat would misorder" >&2; exit 2; }
            fi
          fi
          emit_entry "$cimg" "$b"; last=$cimg; total=$(awk -v t="$total" -v s="$b" 'BEGIN{printf "%.3f", t+s}');;
        frames)
          from=$a; to=$b
          case "$from$to" in *[!0-9-]*) echo "FAIL: frames range must be integers: $from..$to" >&2; exit 2;; esac
          [ "$to" -lt 0 ] && to=$((n-1))
          if [ "$from" -lt 0 ] || [ "$to" -ge "$n" ] || [ "$from" -gt "$to" ]; then
            echo "FAIL: frames range $from..$to outside 0..$((n-1)) ($n frames)" >&2; exit 2
          fi
          for ((j=from; j<=to; j++)); do
            emit_entry "${all_frames[$j]}" "$frame_dur"
          done
          last=${all_frames[$to]}
          total=$(awk -v t="$total" -v c=$((to-from+1)) -v fd="$frame_dur" 'BEGIN{printf "%.3f", t+c*fd}');;
        *) echo "FAIL: bad placement directive: $d (expected card|frames)" >&2; exit 2;;
      esac
    done < "$cards/placement.tsv"
    [ -n "$last" ] || { echo "FAIL: placement.tsv is empty" >&2; exit 2; }
    # concat demuxer ignores the final duration and the trailing repeat entry
    # would inherit the previous duration; give it one 30 fps frame instead
    printf "file '%s'\nduration 0.033333\n" "$last"
  } > "$list"
  echo "cards timeline built: $n captured frames + cards, expected duration ~${total}s"
  vf="${scale_vf},format=yuv420p${drawtext_vf},fps=30"
  # -t clamps the concat demuxer's estimated trailing duration (it reuses the
  # last stated duration for the repeat entry); +0.1s epsilon keeps the tail
  "$ffmpeg_bin" -y -loglevel error -f concat -safe 0 -i "$list" \
    -vf "$vf" -r 30 -t "$(awk -v t="$total" 'BEGIN{printf "%.3f", t+0.1}')" \
    -c:v libx264 -preset "$preset" -crf "$crf" -movflags +faststart "$out" || {
      echo "FAIL: ffmpeg encoding failed (cards timeline)" >&2; exit 2; }
else
  vf="${scale_vf},format=yuv420p${drawtext_vf}"
  # -pattern_type glob needs an ffmpeg built with glob support (glibc builds have
  # it; musl/some macOS builds do not). On failure retry with the %06d sequence.
  if ! "$ffmpeg_bin" -y -loglevel error -framerate "$fps" -pattern_type glob -i "$frames/frame-*.$ext" \
       -vf "$vf" -r 30 -c:v libx264 -preset "$preset" -crf "$crf" -movflags +faststart "$out"; then
    echo "glob pattern failed; retrying with sequence pattern" >&2
    first=$(ls "$frames"/frame-*.$ext | sort | head -1)
    base=${first%*.$ext}
    "$ffmpeg_bin" -y -loglevel error -framerate "$fps" -i "${base}%06d.$ext" \
      -vf "$vf" -r 30 -c:v libx264 -preset "$preset" -crf "$crf" -movflags +faststart "$out" || {
        echo "FAIL: ffmpeg encoding failed" >&2; exit 2; }
  fi
fi
[ -s "$out" ] || { echo "FAIL: no output written: $out" >&2; exit 2; }
echo "wrote $out (preset=$preset crf=$crf${cards:+ cards=$cards})"
