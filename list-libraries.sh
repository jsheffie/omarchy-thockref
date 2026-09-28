#!/bin/bash
# Emits a JSON array of {path, name, text} for every Markdown file directly
# inside the ThockRef data directory. Sorting and display-name derivation
# happen in ThockRefModel.js so both platforms share one definition.
#
#   $1  data directory (default: ${XDG_CONFIG_HOME:-$HOME/.config}/thockref)
#
# The directory is created if missing, matching the macOS app.

set -u

dir=${1:-${XDG_CONFIG_HOME:-$HOME/.config}/thockref}
mkdir -p "$dir" 2>/dev/null
if [[ ! -d $dir ]]; then
  echo '[]'
  exit 0
fi

find -L "$dir" -mindepth 1 -maxdepth 1 -type f -iname '*.md' ! -name '.*' -print0 2>/dev/null |
  while IFS= read -r -d '' file; do
    # -R -s reads the whole file as one JSON string. A file that is not valid
    # UTF-8 or cannot be read is skipped, like the Swift app dropping it.
    jq -Rs --arg path "$file" --arg name "${file##*/}" \
      '{path: $path, name: $name, text: .}' "$file" 2>/dev/null
  done |
  jq -s '.'
