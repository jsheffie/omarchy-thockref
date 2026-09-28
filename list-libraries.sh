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
# producer bounds it: only regular files (no symlinks), each at most
# THOCKREF_MAX_FILE_BYTES (1 MiB), and at most THOCKREF_MAX_TOTAL_BYTES (8 MiB)
# in total, taken in filename order. Anything past a cap is skipped with a
# note on stderr rather than read.

set -u

dir=${1:-${XDG_CONFIG_HOME:-$HOME/.config}/thockref}
mkdir -p "$dir" 2>/dev/null
if [[ ! -d $dir ]]; then
  echo '[]'
  exit 0
fi

max_file_bytes=${THOCKREF_MAX_FILE_BYTES:-1048576}
max_total_bytes=${THOCKREF_MAX_TOTAL_BYTES:-8388608}
total=0

# -type f without -L: a symlink is never followed, so a link cannot point the
# lister at something outside the data directory.
find "$dir" -mindepth 1 -maxdepth 1 -type f -iname '*.md' ! -name '.*' -print0 2>/dev/null |
  sort -z |
  while IFS= read -r -d '' file; do
    size=$(stat -c %s -- "$file" 2>/dev/null) || continue
    if (( size > max_file_bytes )); then
      echo "list-libraries: skipping $file ($size bytes is over the $max_file_bytes byte limit)" >&2
      continue
    fi
    if (( total + size > max_total_bytes )); then
      echo "list-libraries: stopping at $file (the $max_total_bytes byte total limit is reached)" >&2
      break
    fi
    total=$(( total + size ))
    # -R -s reads the whole file as one JSON string. A file that is not valid
    # UTF-8 or cannot be read is skipped, like the Swift app dropping it.
    jq -Rs --arg path "$file" --arg name "${file##*/}" \
      '{path: $path, name: $name, text: .}' "$file" 2>/dev/null
  done |
  jq -s '.'
