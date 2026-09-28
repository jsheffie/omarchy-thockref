#!/bin/bash
# Regression tests for list-libraries.sh: the byte bounds and the regular-file
# check must hold on what is actually read, even when the directory changes
# between the listing and the read.
#
# Run: bash test/list-libraries.test.sh
#
# The "after listing" cases put a `sort` shim first in PATH. It runs the real
# sort to completion, then mutates the data directory, then releases the
# listing, so the lister always sees the mutated file when it opens it.

set -u

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
lister=$root/list-libraries.sh
real_sort=$(command -v sort)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

shim=$tmp/shim
mkdir -p "$shim"
cat > "$shim/sort" <<EOF
#!/bin/bash
out=\$(mktemp)
"$real_sort" "\$@" > "\$out"
eval "\${AFTER_LISTING:-}"
cat "\$out"
rm -f "\$out"
EOF
chmod +x "$shim/sort"

failed=0
pass() { echo "ok - $1"; }
fail() { echo "not ok - $1"; echo "  $2"; failed=1; }

fresh_dir() {
  rm -rf "$tmp/data"
  mkdir -p "$tmp/data"
  echo "$tmp/data"
}

# run <name> [env assignments...] -- runs the lister, captures stdout/stderr
run() {
  env "$@" bash "$lister" "$dir" > "$tmp/stdout" 2> "$tmp/stderr"
}

names() { jq -r '.[].name' "$tmp/stdout" | paste -sd, -; }

# ---------------------------------------------------------------------------

dir=$(fresh_dir)
printf '| a | one |\n' > "$dir/b.md"
printf '| b | two |\n' > "$dir/a.md"
printf 'not markdown\n' > "$dir/notes.txt"
printf 'hidden\n' > "$dir/.hidden.md"
run
if [[ $(names) == "a.md,b.md" && $(jq -r '.[0].text' "$tmp/stdout") == "| b | two |" ]]; then
  pass "lists markdown files in name order with their text"
else
  fail "lists markdown files in name order with their text" "$(cat "$tmp/stdout")"
fi

dir=$(fresh_dir)
printf 'SECRET\n' > "$tmp/secret.md"
ln -s "$tmp/secret.md" "$dir/link.md"
printf '| k | v |\n' > "$dir/real.md"
run
if [[ $(names) == "real.md" ]] && ! grep -q SECRET "$tmp/stdout"; then
  pass "a symlink present at listing time is ignored"
else
  fail "a symlink present at listing time is ignored" "$(cat "$tmp/stdout")"
fi

dir=$(fresh_dir)
head -c 2000 /dev/zero | tr '\0' 'x' > "$dir/big.md"
printf 'small\n' > "$dir/small.md"
run THOCKREF_MAX_FILE_BYTES=1000
if [[ $(names) == "small.md" ]] && grep -q 'big.md (over the 1000 byte limit)' "$tmp/stderr"; then
  pass "a file over the per-file limit is skipped"
else
  fail "a file over the per-file limit is skipped" "$(cat "$tmp/stdout" "$tmp/stderr")"
fi

dir=$(fresh_dir)
for n in 1 2 3; do head -c 400 /dev/zero | tr '\0' 'x' > "$dir/$n.md"; done
run THOCKREF_MAX_TOTAL_BYTES=1000
if [[ $(names) == "1.md,2.md" ]] && grep -q '3.md (the 1000 byte total limit is reached)' "$tmp/stderr"; then
  pass "files past the total limit are skipped"
else
  fail "files past the total limit are skipped" "$(cat "$tmp/stdout" "$tmp/stderr")"
fi

# Growth after listing: the file is small when listed and grows before it is
# read. Only the bytes actually read count, so it must be skipped.
dir=$(fresh_dir)
printf 'small\n' > "$dir/grows.md"
printf 'fine\n' > "$dir/other.md"
run PATH="$shim:$PATH" THOCKREF_MAX_FILE_BYTES=1000 \
  AFTER_LISTING="head -c 5000 /dev/zero | tr '\\0' 'x' >> '$dir/grows.md'"
if [[ $(names) == "other.md" ]] && grep -q 'grows.md (over the 1000 byte limit)' "$tmp/stderr"; then
  pass "a file that grows after the listing is skipped"
else
  fail "a file that grows after the listing is skipped" "$(cat "$tmp/stdout" "$tmp/stderr")"
fi

# Growth after listing against the total limit.
dir=$(fresh_dir)
printf 'a\n' > "$dir/1.md"
printf 'b\n' > "$dir/2.md"
run PATH="$shim:$PATH" THOCKREF_MAX_TOTAL_BYTES=100 THOCKREF_MAX_FILE_BYTES=1000 \
  AFTER_LISTING="head -c 99 /dev/zero | tr '\\0' 'x' > '$dir/1.md'"
if [[ $(names) == "1.md" ]] && grep -q '2.md (the 100 byte total limit is reached)' "$tmp/stderr"; then
  pass "growth after the listing still counts against the total limit"
else
  fail "growth after the listing still counts against the total limit" "$(cat "$tmp/stdout" "$tmp/stderr")"
fi

# Swap after listing: a regular file is replaced by a symlink to a file outside
# the directory before it is opened. The descriptor no longer matches the
# directory entry, so it must not be read.
dir=$(fresh_dir)
printf 'SECRET\n' > "$tmp/secret.md"
printf 'placeholder\n' > "$dir/swapped.md"
printf 'fine\n' > "$dir/other.md"
run PATH="$shim:$PATH" \
  AFTER_LISTING="ln -sfn '$tmp/secret.md' '$dir/swapped.md'"
if [[ $(names) == "other.md" ]] && ! grep -q SECRET "$tmp/stdout" && grep -q 'swapped.md (not a regular file)' "$tmp/stderr"; then
  pass "a file swapped for a symlink after the listing is not read"
else
  fail "a file swapped for a symlink after the listing is not read" "$(cat "$tmp/stdout" "$tmp/stderr")"
fi

# Swap after listing to a symlink that points at another regular file inside
# the directory: still a symlink, still skipped (the target is listed itself).
dir=$(fresh_dir)
printf 'placeholder\n' > "$dir/swapped.md"
printf 'fine\n' > "$dir/other.md"
run PATH="$shim:$PATH" \
  AFTER_LISTING="ln -sfn '$dir/other.md' '$dir/swapped.md'"
if [[ $(names) == "other.md" ]]; then
  pass "a symlink swapped in that points inside the directory is skipped too"
else
  fail "a symlink swapped in that points inside the directory is skipped too" "$(cat "$tmp/stdout" "$tmp/stderr")"
fi

dir=$(fresh_dir)
head -c 3000 /dev/zero | tr '\0' 'x' > "$dir/a.md"
run THOCKREF_MAX_OUTPUT_BYTES=1000
if [[ $(cat "$tmp/stdout") == "[]" ]] && grep -q 'dropping the scan' "$tmp/stderr"; then
  pass "a scan over the output limit is replaced by an empty array"
else
  fail "a scan over the output limit is replaced by an empty array" "$(cat "$tmp/stdout" "$tmp/stderr")"
fi

dir=$tmp/missing/thockref
run
if [[ -d $dir && $(cat "$tmp/stdout") == "[]" ]]; then
  pass "a missing directory is created and yields an empty array"
else
  fail "a missing directory is created and yields an empty array" "$(cat "$tmp/stdout" "$tmp/stderr")"
fi

dir=$(fresh_dir)
printf '\xff\xfe bad utf-8\n' > "$dir/bad.md"
printf '| k | v |\n' > "$dir/good.md"
run
if jq -e 'length == 2 and (.[0].text | length > 0)' "$tmp/stdout" > /dev/null; then
  pass "invalid UTF-8 is not fatal to the scan"
else
  fail "invalid UTF-8 is not fatal to the scan" "$(cat "$tmp/stdout" "$tmp/stderr")"
fi

if (( failed )); then
  echo "FAILED"
  exit 1
fi
echo "all list-libraries tests passed"
