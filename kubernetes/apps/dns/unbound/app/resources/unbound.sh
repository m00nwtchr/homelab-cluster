#!/bin/bash
# shellcheck disable=SC2155,SC2004

reserved=12582912
availableMemory=$((1024 * $( (grep MemAvailable /proc/meminfo || grep MemTotal /proc/meminfo) | sed 's/[^0-9]//g' ) ))
memoryLimit=$availableMemory
[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ] && memoryLimit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes | sed 's/[^0-9]//g')
[[ ! -z $memoryLimit && $memoryLimit -gt 0 && $memoryLimit -lt $availableMemory ]] && availableMemory=$memoryLimit
if [ $availableMemory -le $(($reserved * 2)) ]; then
    echo "Not enough memory" >&2
    exit 1
fi
availableMemory=$(($availableMemory - $reserved))
rr_cache_size=$(($availableMemory / 3))
# Use roughly twice as much rrset cache memory as msg cache memory
msg_cache_size=$(($rr_cache_size / 2))
nproc=$(nproc)
export nproc
if [ "$nproc" -gt 1 ]; then
    threads=$((nproc - 1))
    # Calculate base 2 log of the number of processors
    nproc_log=$(perl -e 'printf "%5.5f\n", log($ENV{nproc})/log(2);')

    # Round the logarithm to an integer
    rounded_nproc_log="$(printf '%.*f\n' 0 "$nproc_log")"

    # Set *-slabs to a power of 2 close to the num-threads value.
    # This reduces lock contention.
    slabs=$(( 2 ** rounded_nproc_log ))
else
    threads=1
    slabs=4
fi

set -x

echo "DBG: msg=$msg_cache_size rr=$rr_cache_size thr=$threads slabs=$slabs" >&2

# ── 4. render template ───────────────────────────────────────────────────────
sed -e "s/@MSG_CACHE_SIZE@/$msg_cache_size/" \
    -e "s/@RR_CACHE_SIZE@/$rr_cache_size/" \
    -e "s/@THREADS@/$threads/" \
    -e "s/@SLABS@/$slabs/" \
    /config/unbound.conf > /etc/unbound/unbound.conf

# ── 6. launch ────────────────────────────────────────────────────────────────
/opt/unbound/sbin/unbound-anchor -a /var/lib/unbound/root.key
exec /opt/unbound/sbin/unbound -d -c /etc/unbound/unbound.conf
