# caddy-dns-ednsde — moved

> **This repository is archived.** The module now lives at
> **[caddy-dns/ednsde](https://github.com/caddy-dns/ednsde)** as
> `github.com/caddy-dns/ednsde`, maintained inside the caddy-dns organisation,
> and the libdns provider behind it at
> **[libdns/ednsde](https://github.com/libdns/ednsde)**.
>
> Build with `xcaddy build --with github.com/caddy-dns/ednsde` from now on.
> Nothing here is maintained any more; the history is kept because the old module
> path still resolves for anyone who has it in a `go.mod`.

A [Caddy](https://caddyserver.com) DNS module for **eDNS** ([edns.de](https://edns.de)),
so Caddy can obtain certificates through the ACME **DNS-01** challenge — including
wildcard certificates, and for hosts that are not reachable from the internet at
all.

The provider itself lives in [libdns-ednsde](https://github.com/chris299/libdns-ednsde);
this repository is only the Caddy module wrapper.

## Building

This module is not in the standard Caddy distribution. Build Caddy with
[xcaddy](https://github.com/caddyserver/xcaddy):

```sh
xcaddy build --with github.com/chris299/caddy-dns-ednsde
```

Verify it is present:

```sh
./caddy list-modules | grep dns.providers.ednsde
```

## Configuration

Caddyfile, token as an argument:

```caddyfile
tls {
	dns ednsde {env.EDNS_TOKEN}
}
```

or as a block:

```caddyfile
tls {
	dns ednsde {
		api_token {env.EDNS_TOKEN}
	}
}
```

Giving the token both ways at once is an error — a credential with two sources
of truth is one waiting to drift.

JSON:

```json
{
	"module": "acme",
	"challenges": {
		"dns": {
			"provider": {
				"name": "ednsde",
				"api_token": "YOUR_EDNS_ACCESS_TOKEN"
			}
		}
	}
}
```

### Recommended timing, and the one thing that will bite you

```caddyfile
tls {
	dns ednsde {env.EDNS_TOKEN}
	propagation_delay 30s
	propagation_timeout 10m
}
```

eDNS publishes a challenge record on a name that did not exist before after
about **23 seconds**, measured across both authoritative nameservers of a live
zone. `propagation_delay 30s` simply avoids spending that time on lookups that
cannot yet succeed.

The long timeout is the important part, and the reason is not eDNS but DNS
itself. `_acme-challenge.<your-host>` normally does not exist before the first
issuance, so the first lookup of it is answered with NXDOMAIN — and **that
negative answer is cached for your zone's SOA minimum**. Until it expires, the
propagation check cannot resolve the name's authoritative servers and keeps
reporting "not ready". In a measured run against a zone with a 300-second SOA
minimum, the first attempt failed at exactly 300 seconds and the retry then
succeeded in 40.

So: **check your zone's SOA minimum.**

```sh
dig +short SOA example.com | awk '{print "negative TTL:", $NF}'
```

If it is 86400, a first issuance can be stuck for a *day*, and no ACME client
setting will help. Lower it to 300 in the eDNS zone settings before you rely on
DNS-01. With a low SOA minimum, a ten-minute timeout lets the first attempt
succeed rather than fail once and retry.

### A complete example

A reverse proxy with a wildcard certificate, reachable only over HTTPS:

```caddyfile
{
	email you@example.com
}

*.example.com {
	tls {
		dns ednsde {env.EDNS_TOKEN}
		propagation_delay 30s
		propagation_timeout 5m
	}
	reverse_proxy 127.0.0.1:8080
}
```

## Getting an access token

1. In the eDNS web interface: **SSL-Zertifikate → Automation-API-Verwaltung →
   API-Zugang anlegen**.
2. Open the zone and select that token on its **DNS-01-Challenge** tab.

Step 2 is easy to miss and produces a `401` that reads exactly like an invalid
token — the API does not distinguish the two. One token may be assigned to
several zones.

## Testing

Unit tests need nothing but Go:

```sh
go test ./...
```

The end-to-end test builds Caddy with this module, obtains **real certificates
from Let's Encrypt staging** over DNS-01, and proves the result by proxying a
request to a second Caddy instance. It writes into a real zone and needs a real
token:

```sh
EDNS_TOKEN=... ./e2e/run.sh
```

See [e2e/README.md](e2e/README.md) for what it does and what it requires.

## Licence

MIT
