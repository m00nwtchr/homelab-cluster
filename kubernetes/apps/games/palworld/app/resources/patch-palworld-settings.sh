#!/bin/bash
# Patch PalWorldSettings.ini from image defaults + PALWORLD_* env overrides.
# Keys are auto-derived from the base INI; no hardcoded list.
# Usage: invoked by the HelmRelease as the container entrypoint; server
# args are forwarded via "$@" to PalServer.sh after patching.

set -euo pipefail

BASE_INI="${PALWORLD_BASE_INI:-/pal/Package/DefaultPalWorldSettings.ini}"
OUT_INI="${PALWORLD_OUT_INI:-/pal/Package/Pal/Saved/Config/LinuxServer/PalWorldSettings.ini}"
RUN_AS="${PALWORLD_UID_GID:-999:999}"

log() { printf '[patch-palworld-settings] %s\n' "$*" >&2; }

if [[ ! -f "$BASE_INI" ]]; then
  log "base INI not found at $BASE_INI"
  exit 1
fi

# Parse the OptionSettings=(…) line into ordered KEY\tORIGINAL_VALUE pairs.
# Awk state machine respects double-quoted strings (with backslash escapes)
# and nested parentheses, splitting only on top-level commas.
parse_pairs() {
  awk '
    function emit(s,   idx) {
      idx = index(s, "=")
      if (idx > 0) print substr(s, 1, idx - 1) "\t" substr(s, idx + 1)
    }
    BEGIN { depth = 0; in_str = 0; cur = "" }
    {
      line = $0
      # Skip non-OptionSettings lines (e.g. the [/Script/...] section header)
      # so their contents cannot leak into cur and corrupt the first key.
      if (line !~ /^OptionSettings=\(/) next
      # Tolerate CRLF input; strip a trailing CR so anchors and emit() work.
      sub(/\r$/, "", line)
      sub(/^OptionSettings=\(/, "", line)
      sub(/\)$/, "", line)
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (in_str) {
          cur = cur c
          if (c == "\\") { cur = cur substr(line, i + 1, 1); i++; continue }
          if (c == "\"") in_str = 0
          continue
        }
        if (c == "\"")       { in_str = 1; cur = cur c; continue }
        if (c == "(")        { depth++;   cur = cur c; continue }
        if (c == ")")        { depth--;   cur = cur c; continue }
        if (c == "," && depth == 0) { emit(cur); cur = ""; continue }
        cur = cur c
      }
      if (length(cur) > 0) emit(cur)
    }
  ' "$BASE_INI"
}

# Convert INI key -> env var name.
#   Difficulty        -> PALWORLD_DIFFICULTY
#   RandomizerType    -> PALWORLD_RANDOMIZER_TYPE
#   bIsMultiplay      -> PALWORLD_IS_MULTIPLAY        (leading 'b' stripped)
#   RCONEnabled       -> PALWORLD_RCON_ENABLED
to_env_name() {
  local key="$1"
  if [[ "$key" =~ ^b[A-Z] ]]; then
    key="${key#b}"
  fi
  local upper_snake
  upper_snake=$(printf '%s' "$key" \
    | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g; s/([A-Z])([A-Z][a-z])/\1_\2/g' \
    | tr '[:lower:]' '[:upper:]')
  printf 'PALWORLD_%s' "$upper_snake"
}

# Reformat the env value to match the original value's type.
format_value() {
  local orig="$1" new="$2"
  # bool
  if [[ "$orig" =~ ^(True|False|true|false)$ ]]; then
    printf '%s' "$new"; return
  fi
  # quoted string
  if [[ "$orig" =~ ^\".*\"$ ]]; then
    local escaped
    escaped=$(printf '%s' "$new" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    printf '"%s"' "$escaped"; return
  fi
  # list
  if [[ "$orig" =~ ^\(.*\)$ ]]; then
    printf '(%s)' "$new"; return
  fi
  # number
  if [[ "$orig" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
    printf '%s' "$new"; return
  fi
  # enum / bare identifier / empty -> verbatim
  printf '%s' "$new"
}

# Build the new OptionSettings=(…) line, applying any overrides.
new_line="OptionSettings=("
first=1
while IFS=$'\t' read -r key orig_val; do
  [[ -z "${key:-}" ]] && continue
  env_name=$(to_env_name "$key")
  new_val="$orig_val"
  # Indirect expansion: only override if var is set AND non-empty.
  if [[ -n "${!env_name+x}" && -n "${!env_name}" ]]; then
    new_val=$(format_value "$orig_val" "${!env_name}")
    # Never echo the env value — PALWORLD_* may carry secrets (passwords,
    # tokens, RCON keys). Operators verify the patched file directly.
    log "override ${key} (env ${env_name}=<redacted>)"
  fi
  if (( first )); then
    new_line+="${key}=${new_val}"
    first=0
  else
    new_line+=",${key}=${new_val}"
  fi
done < <(parse_pairs)
new_line+=")"

mkdir -p "$(dirname "$OUT_INI")"

# Pass the base file through awk, swapping only the OptionSettings=(…) line
# for our patched version. Preserves leading comments (e.g. "; This file…"),
# the [/Script/…] section header, and any trailing blank lines — only the
# OptionSettings line changes. CRLF in the base is normalised to LF for
# consistency with the patched line.
awk -v patched="$new_line" '
  /^OptionSettings=\(/ {
    gsub(/\r/, "", patched)
    print patched
    next
  }
  { gsub(/\r/, "", $0); print }
' "$BASE_INI" > "$OUT_INI"

# Match the pod's runAsUser/runAsGroup so the server can read the file.
if command -v chown >/dev/null 2>&1; then
  chown "$RUN_AS" "$OUT_INI" 2>/dev/null || true
fi

log "wrote $OUT_INI"

exec /bin/bash /pal/Package/PalServer.sh "$@"
