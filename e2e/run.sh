#!/usr/bin/env bash
#
# End-to-end test: build Caddy with the ednsde module, have it obtain real
# certificates from Let's Encrypt staging over the ACME DNS-01 challenge, and
# prove that it then serves a request by proxying it to a second Caddy.
#
# Requires: go, xcaddy, openssl, curl, and EDNS_TOKEN in the environment.
# The same script runs locally and on a GitHub Actions ubuntu runner.
#
#   EDNS_TOKEN=... ./run.sh
#
set -euo pipefail

cd "$(dirname "$0")"

ZONE=${E2E_ZONE:-winkler.tel}
# A plain host, and a wildcard one level below it. The wildcard must not cove
# the plain host: Caddy would then obtain a single certificate for both and the
# non-wildcard path would silently go untested.
HOST=${E2E_HOST:-vault.$ZONE}
WILDCARD=${E2E_WILDCARD:-*.e2e.$ZONE}
WILDCARD_HOST=${E2E_WILDCARD_HOST:-probe.e2e.$ZONE}
BACKEND_BODY="Hallo Welt von der Backend-Instanz"
# Generous, because a name that never existed stays negatively cached for the
# zone's SOA minimum before the propagation check can succeed.
CERT_TIMEOUT=${E2E_CERT_TIMEOUT:-900}

RUN_DIR=./run
CADDY=./caddy

EDNS_API=${EDNS_API:-https://dns-challenge.edns.de}
# 43 characters, matching the shape of a real ACME digest, and certain never to
# exist in any zone.
PREFLIGHT_VALUE=preflight0000000000000000000000000000000000

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
fail() { printf '\033[31mFEHLGESCHLAGEN: %s\033[0m\n' "$*" >&2; exit 1; }

: "${EDNS_TOKEN:?EDNS_TOKEN muss gesetzt sein (lokal aus der .env, in CI aus dem Secret)}"
export EDNS_TOKEN

backend_pid=""
proxy_pid=""

cleanup() {
	local status=$?
	log "Aufräumen"
	[ -n "$proxy_pid" ] && kill "$proxy_pid" 2>/dev/null || true
	[ -n "$backend_pid" ] && kill "$backend_pid" 2>/dev/null || true
	# Give Caddy a moment to remove its challenge records before we exit.
	sleep 3
	[ -n "$proxy_pid" ] && wait "$proxy_pid" 2>/dev/null || true
	[ -n "$backend_pid" ] && wait "$backend_pid" 2>/dev/null || true
	# Only dump the log if this run actually started a proxy. Failing earlier --
	# in the preflight, say -- would otherwise print a stale log from a previous
	# run and send the reader chasing the wrong problem.
	if [ $status -ne 0 ] && [ -n "$proxy_pid" ] && [ -f "$RUN_DIR/proxy.log" ]; then
		echo "--- letzte 40 Zeilen aus proxy.log ---"
		tail -40 "$RUN_DIR/proxy.log"
	fi
	exit $status
}
trap cleanup EXIT

# Fail fast on a bad token. Without this, a wrong or unassigned access token
# looks exactly like slow propagation: Caddy retries quietly and the script sits
# here for the full certificate timeout before anyone sees the 401. Removing a
# challenge value that cannot exist is answered with result_code 5 and changes
# nothing in the zone, which makes it a free credentials check.
log "Zugangsdaten gegen die eDNS-API prüfen"
preflight=$(curl -sS --max-time 20 -w '\n%{http_code}' -X POST "$EDNS_API" \
	-H "Content-Type: application/json" \
	-H "X-API-TOKEN: $EDNS_TOKEN" \
	-d "{\"action\":\"removeChallengeRecord\",\"domain\":\"$ZONE\",\"subdomain\":\"_acme-challenge.preflight\",\"challenge_token\":\"$PREFLIGHT_VALUE\"}") \
	|| fail "die eDNS-Challenge-API unter $EDNS_API ist nicht erreichbar"

preflight_status=$(printf '%s' "$preflight" | tail -n 1)
preflight_body=$(printf '%s' "$preflight" | sed '$d')

case "$preflight_status" in
	200)
		echo "  Token ist gültig und der Zone $ZONE zugewiesen."
		;;
	401)
		fail "eDNS lehnt den Access-Token für $ZONE ab (HTTP 401).
  Die API unterscheidet nicht zwischen einem ungültigen Token und einem, de
  dieser Zone nicht zugewiesen ist. Prüfe beides:
    1. Ist EDNS_TOKEN korrekt gesetzt? Lokal aus der .env, in CI als Secret.
       Ein häufiger Fehler ist ein Secret, das versehentlich den Wert '-' trägt,
       weil 'gh secret set --body -' das Minuszeichen als Wert nimmt statt von
       stdin zu lesen. Richtig ist: printf '%s' \"\$TOKEN\" | gh secret set EDNS_TOKEN
    2. Ist der Token in der Zone auf dem Reiter DNS-01-Challenge ausgewählt?
  Antwort der API: $preflight_body"
		;;
	*)
		fail "unerwartete Antwort der eDNS-API (HTTP $preflight_status): $preflight_body"
		;;
esac

log "Caddy mit dem ednsde-Modul bauen"
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"

# This module always comes from the working tree, so the test covers uncommitted
# changes rather than whatever is published. The libdns provider does too, but
# only when it happens to be checked out next to this repository -- which is the
# case in the combined development workspace and not in CI.
build_args=(--with "github.com/chris299/caddy-dns-ednsde=$(pwd)/..")
if [ -f ../../libdns-ednsde/go.mod ]; then
	echo "Benutze das lokale libdns-ednsde aus dem Nachbarverzeichnis."
	build_args+=(--with "github.com/chris299/libdns-ednsde=$(pwd)/../../libdns-ednsde")
else
	echo "Kein lokales libdns-ednsde gefunden -- benutze die veröffentlichte Version."
fi
xcaddy build "${build_args[@]}" --output "$CADDY"
"$CADDY" list-modules | grep -q '^dns.providers.ednsde$' \
	|| fail "das Modul dns.providers.ednsde fehlt im Build"
echo "Modul dns.providers.ednsde ist im Binary."

log "Backend starten (statisches Hallo Welt auf 8081)"
"$CADDY" run --config Caddyfile.backend >"$RUN_DIR/backend.log" 2>&1 &
backend_pid=$!
for _ in $(seq 1 30); do
	if curl -fsS http://127.0.0.1:8081/ 2>/dev/null | grep -q "$BACKEND_BODY"; then break; fi
	sleep 1
done
curl -fsS http://127.0.0.1:8081/ | grep -q "$BACKEND_BODY" \
	|| fail "das Backend antwortet nicht auf 127.0.0.1:8081"
echo "Backend antwortet."

log "Proxy starten -- er fordert jetzt Zertifikate über DNS-01 an"
"$CADDY" run --config Caddyfile.proxy >"$RUN_DIR/proxy.stdout.log" 2>&1 &
proxy_pid=$!

# Waits until the proxy serves the backend's body for the given name.
wait_for_https() {
	local host=$1 deadline=$((SECONDS + CERT_TIMEOUT))
	while [ $SECONDS -lt $deadline ]; do
		if curl -sk --max-time 10 --resolve "$host:8443:127.0.0.1" \
			"https://$host:8443/" 2>/dev/null | grep -q "$BACKEND_BODY"; then
			echo "  $host liefert nach $((SECONDS))s die Backend-Antwort."
			return 0
		fi
		kill -0 "$proxy_pid" 2>/dev/null || fail "der Proxy ist beendet worden"
		sleep 5
	done
	return 1
}

# Checks issuer and SAN of the certificate actually presented for a name.
check_cert() {
	local host=$1 want_san=$2 cert issuer sans
	cert=$(echo | openssl s_client -connect 127.0.0.1:8443 -servername "$host" 2>/dev/null)
	issuer=$(echo "$cert" | openssl x509 -noout -issuer 2>/dev/null || true)
	sans=$(echo "$cert" | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)

	echo "  $host"
	echo "    $issuer"
	echo "    $(echo "$sans" | tail -1 | sed 's/^ *//')"

	case "$issuer" in
		*STAGING*) ;;
		*) fail "$host wurde nicht von der Let's-Encrypt-Staging-CA ausgestellt: $issuer" ;;
	esac
	echo "$sans" | grep -qF "$want_san" \
		|| fail "$host trägt nicht den erwarteten SAN $want_san"
}

log "Auf das Zertifikat für $HOST warten (bis zu ${CERT_TIMEOUT}s)"
wait_for_https "$HOST" || fail "innerhalb von ${CERT_TIMEOUT}s kein Zertifikat für $HOST"

log "Auf das Wildcard-Zertifikat für $WILDCARD warten"
wait_for_https "$WILDCARD_HOST" || fail "innerhalb von ${CERT_TIMEOUT}s kein Wildcard-Zertifikat"

log "Zertifikate prüfen"
# Two distinct certificates: the plain host must present its own name, the
# wildcard probe must present the wildcard. If the proxy ever served the same
# certificate for both, one of these fails.
check_cert "$HOST" "DNS:$HOST"
check_cert "$WILDCARD_HOST" "DNS:$WILDCARD"

log "Beweisen, dass wirklich das Backend geantwortet hat"
body=$(curl -sk --resolve "$HOST:8443:127.0.0.1" "https://$HOST:8443/")
[ "$body" = "$BACKEND_BODY" ] || fail "unerwartete Antwort: $body"
echo "  \"$body\""

log "ERFOLG"
echo "Caddy hat über die eDNS-Challenge-API zwei Zertifikate von Let's Encrypt"
echo "Staging bezogen -- eines für $HOST, eines für $WILDCARD -- und beide"
echo "Anfragen an das Backend weitergereicht."
