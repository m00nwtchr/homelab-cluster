# scan a secret for NUL bytes in any data key
scan_secret() {
	ns="$1"
	name="$2"

	for k in $(kubectl -n "$ns" get secret "$name" -o jsonpath='{.data}' | jq -r 'keys[]'); do
		val="$(kubectl -n "$ns" get secret "$name" -o jsonpath="{.data.$k}" | base64 -d || true)"
		if printf '%s' "$val" | LC_ALL=C grep -q $'\x00'; then
			echo "FOUND NUL: $ns/$name key=$k"
		fi
	done
}

scan_secret ai litellm
# scan_secret ai litellm-postgres
