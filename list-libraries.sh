#!/bin/bash
# Emits a JSON array of {path, name, text} for every Markdown file directly
# inside the ThockRef data directory. Sorting and display-name derivation
# happen in ThockRefModel.js so both platforms share one definition.
#
#   $1  data directory (default: ${XDG_CONFIG_HOME:-$HOME/.config}/thockref)
#
# The directory is created if missing, matching the macOS app.
#
# The output is parsed inside the long-lived omarchy-shell process, so the
# producer bounds it, and every bound is enforced on the bytes actually read,
# not on a size looked up earlier:
#
#   - A file is opened once and kept open. It counts only if the descriptor
#     refers to the same inode as the directory entry and that entry is a
#     regular file, so a symlink (present from the start or swapped in after
#     the listing) is never read.
#   - At most THOCKREF_MAX_FILE_BYTES + 1 (1 MiB + 1) bytes are read from that
#     descriptor. A file that turns out larger, including one that grew after
#     the listing, is skipped without being emitted.
#   - Files are taken in filename order until THOCKREF_MAX_TOTAL_BYTES (8 MiB)
#     of them have been read; the rest are skipped.
#   - The JSON is assembled in a private temporary file and only written to
#     stdout if it is at most THOCKREF_MAX_OUTPUT_BYTES (20 MiB). Otherwise
#     "[]" is emitted, so the consumer never receives more than that.
#
# Anything skipped is noted on stderr.

set -u

dir=${1:-${XDG_CONFIG_HOME:-$HOME/.config}/thockref}
mkdir -p "$dir" 2>/dev/null
if [[ ! -d $dir ]]; then
  echo '[]'
  exit 0
fi

max_file_bytes=${THOCKREF_MAX_FILE_BYTES:-1048576}
max_total_bytes=${THOCKREF_MAX_TOTAL_BYTES:-8388608}
max_output_bytes=${THOCKREF_MAX_OUTPUT_BYTES:-20971520}

work=$(mktemp -d "${TMPDIR:-/tmp}/thockref-scan.XXXXXX") || { echo '[]'; exit 0; }
trap 'rm -rf "$work"' EXIT

# lstat of the directory entry versus fstat of the open descriptor. Equal
# output means the entry is a regular file (not a symlink) and the descriptor
# is that very file.
entry_identity() { stat -c '%F %d %i' -- "$1" 2>/dev/null; }
open_identity() { stat -L -c '%F %d %i' -- "/dev/fd/$1" 2>/dev/null; }

total=0
# -type f without -L: a symlink is never followed here either.
find "$dir" -mindepth 1 -maxdepth 1 -type f -iname '*.md' ! -name '.*' -print0 2>/dev/null |
  sort -z |
  while IFS= read -r -d '' file; do
    exec {fd}<"$file" || continue
    entry=$(entry_identity "$file")
    if [[ $entry != "regular "* || $entry != "$(open_identity "$fd")" ]]; then
      echo "list-libraries: skipping $file (not a regular file)" >&2
      exec {fd}<&-
      continue
    fi
    # Bounded read from the held descriptor: one byte past the limit is enough
    # to know the file is too large.
    head -c "$(( max_file_bytes + 1 ))" <&"$fd" > "$work/data"
    exec {fd}<&-
    size=$(stat -c %s -- "$work/data") || continue
    if (( size > max_file_bytes )); then
      echo "list-libraries: skipping $file (over the $max_file_bytes byte limit)" >&2
      continue
    fi
    if (( total + size > max_total_bytes )); then
      echo "list-libraries: skipping $file (the $max_total_bytes byte total limit is reached)" >&2
      continue
    fi
    total=$(( total + size ))
    # -R -s reads the whole file as one JSON string. A file that is not valid
    # UTF-8 or cannot be read is skipped, like the Swift app dropping it.
    jq -Rs --arg path "$file" --arg name "${file##*/}" \
      '{path: $path, name: $name, text: .}' "$work/data" 2>/dev/null
  done |
  jq -s '.' > "$work/out.json" 2>/dev/null

out_size=$(stat -c %s -- "$work/out.json" 2>/dev/null) || out_size=0
if (( out_size == 0 )); then
  echo '[]'
elif (( out_size > max_output_bytes )); then
  echo "list-libraries: dropping the scan ($out_size bytes is over the $max_output_bytes byte output limit)" >&2
  echo '[]'
else
  cat -- "$work/out.json"
fi
