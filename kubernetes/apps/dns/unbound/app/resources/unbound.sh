#!/usr/bin/env bash
# shellcheck disable=SC2155,SC2004

set -euo pipefail

### ───── constants & tunables ────────────────────────────────────────────────
RESERVED=$((12*1024*1024))              # hard floor: 12 MiB we never touch
CACHE_FRACTION="${CACHE_FRACTION:-0.50}"# % of usable RAM we give to caches
RR_TO_MSG_RATIO="${RR_TO_MSG_RATIO:-2}" # RRset cache is 2× msg cache by default
###############################################################################

log2_floor() {          # integer log2, no perl, no bc
    local v=$1 p=0
    while (( v >>= 1 )); do ((p++)); done
    echo "$p"
}

# ── 1. how much RAM can we actually use? ─────────────────────────────────────
read -r _ avail_kib _ < <(grep -m1 -E 'MemAvailable|MemTotal' /proc/meminfo)
phys_bytes=$((avail_kib*1024))

cg_limit=""
# cgroup v1
[[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]] \
  && cg_limit=$(< /sys/fs/cgroup/memory/memory.limit_in_bytes)
# cgroup v2
[[ -z $cg_limit && -r /sys/fs/cgroup/memory.max ]] \
  && cg_raw=$(< /sys/fs/cgroup/memory.max) \
  && [[ $cg_raw != "max" ]] && cg_limit=$cg_raw

cg_limit=${cg_limit//[^0-9]/}           # strip non-digits

if [[ -n $cg_limit && $cg_limit -gt 0 && $cg_limit -lt $phys_bytes ]]; then
    avail_bytes=$cg_limit
else
    avail_bytes=$phys_bytes
fi

if (( avail_bytes <= RESERVED*2 )); then
    echo "ERROR: Only $(($avail_bytes/1024/1024)) MiB available; need >$((RESERVED*2/1024/1024)) MiB." >&2
    exit 1
fi

usable=$((avail_bytes-RESERVED))

# ── 2. cache sizing ──────────────────────────────────────────────────────────
total_cache_bytes=$(awk -v u="$usable" -v f="$CACHE_FRACTION" \
                    'BEGIN{printf "%.0f",u*f}')
rr_cache_size=$(( total_cache_bytes * RR_TO_MSG_RATIO / (RR_TO_MSG_RATIO+1) ))
msg_cache_size=$(( total_cache_bytes - rr_cache_size ))

to_unit() {             # bytes → “64m” / “1g” / raw bytes
    local b=$1
    if   (( b % (1024**3) == 0 )); then echo $((b/1024/1024/1024))g
    elif (( b % (1024**2) == 0 )); then echo $((b/1024/1024))m
    else echo "$b"; fi
}
msg_cache_human=$(to_unit "$msg_cache_size")
rr_cache_human=$(to_unit "$rr_cache_size")

# ── 3. threads & slabs ───────────────────────────────────────────────────────
cpu_total=$(nproc --ignore=0)
if (( cpu_total > 1 )); then
    threads=$((cpu_total-1))
    slabs=$(( 2 ** $(log2_floor "$threads") ))
else
    threads=1
    slabs=1
fi

# ── 4. render template ───────────────────────────────────────────────────────
sed -e "s/@MSG_CACHE_SIZE@/${msg_cache_human}/" \
    -e "s/@RR_CACHE_SIZE@/${rr_cache_human}/" \
    -e "s/@THREADS@/${threads}/" \
    -e "s/@SLABS@/${slabs}/" \
    /config/unbound.conf > /etc/unbound/unbound.conf

# ── 5. show our work ─────────────────────────────────────────────────────────
{
  echo "--- Unbound auto-tune summary --------------------"
  printf "Usable RAM   : %d MiB\n" $((usable/1024/1024))
  printf "Msg cache    : %s\n" "$msg_cache_human"
  printf "RRset cache  : %s\n" "$rr_cache_human"
  printf "Threads      : %s\n" "$threads"
  printf "Slabs        : %s\n" "$slabs"
  echo "--------------------------------------------------"
} >&2

# ── 6. launch ────────────────────────────────────────────────────────────────
/opt/unbound/sbin/unbound-anchor -a /var/lib/unbound/root.key
exec /opt/unbound/sbin/unbound -d -c /etc/unbound/unbound.conf
