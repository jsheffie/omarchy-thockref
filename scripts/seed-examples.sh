#!/bin/sh
# Installs the example shortcut files into ~/.config/thockref in the order
# given by examples/thockref-files-order.
#
# Each file gets a generated NNN- prefix from its position in the order file.
# The app sorts files by name and strips that prefix from the display name.
#
#   seed  copy files that are not installed yet (matched by name, any prefix)
#   dist  remove the copies this script made that are still identical to the
#         examples, then copy every listed file afresh (renumbering them).
#         Files you edited, and files this script never installed, are kept.
set -eu

mode=${1:-}
case "$mode" in
    seed|dist) ;;
    *) echo "usage: $0 seed|dist" >&2; exit 2 ;;
esac

examples_dir=examples
order_file=$examples_dir/thockref-files-order
config_dir=${HOME}/.config/thockref

names=$(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$order_file")

# Validate the whole list before touching the config directory.
status=0
for name in $names; do
    if [ ! -f "$examples_dir/$name" ]; then
        echo "error: $name is listed in $order_file but $examples_dir/$name does not exist" >&2
        status=1
    fi
done
duplicates=$(printf '%s\n' $names | sort | uniq -d)
if [ -n "$duplicates" ]; then
    echo "error: listed more than once in $order_file:" $duplicates >&2
    status=1
fi
[ "$status" -eq 0 ] || exit 1

for f in "$examples_dir"/*.md; do
    name=$(basename "$f")
    if ! printf '%s\n' $names | grep -qxF "$name"; then
        echo "warning: $f is not listed in $order_file and will not be installed" >&2
    fi
done

mkdir -p "$config_dir"

if [ "$mode" = dist ]; then
    # Only a NNN- prefixed file whose name is a listed example and whose
    # contents still match that example is ours to remove.
    for f in "$config_dir"/[0-9][0-9][0-9]-*.md; do
        [ -f "$f" ] || continue
        base=$(basename "$f" | sed 's/^[0-9][0-9][0-9]-//')
        if printf '%s\n' $names | grep -qxF "$base" && cmp -s "$f" "$examples_dir/$base"; then
            rm -f "$f"
            echo "Removed $f"
        fi
    done
fi

n=0
for name in $names; do
    n=$((n + 1))
    dest=$config_dir/$(printf '%03d' "$n")-$name
    existing=$(ls "$config_dir"/[0-9][0-9][0-9]-"$name" "$config_dir/$name" 2>/dev/null | head -n 1)
    if [ -n "$existing" ]; then
        if [ "$mode" = seed ]; then
            echo "Skipped $name (already installed as $existing)"
        else
            echo "Kept $existing (differs from the example, so it is yours)"
        fi
        continue
    fi
    if [ "$mode" = seed ]; then
        echo "Seeded $dest"
    else
        echo "Dist $dest"
    fi
    cp "$examples_dir/$name" "$dest"
done
