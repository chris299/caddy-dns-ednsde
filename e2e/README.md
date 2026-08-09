# End-to-end test

Proves the whole chain works: Caddy, built with this module, obtains **real
certificates from Let's Encrypt staging** through the ACME DNS-01 challenge
solved by the eDNS API, and then serves a request by proxying it to a second
Caddy instance.

Unit tests cannot show this. They can only show that we send the right JSON.
This shows that Let's Encrypt agreed.

## What it does

1. Builds Caddy with `xcaddy`, taking this module from the working tree — so the
   test covers uncommitted changes. If `libdns-ednsde` happens to be checked out
   next to this repository, it is taken from there too; otherwise the published
   version is used.
2. Verifies `dns.providers.ednsde` is actually registered in the binary.
3. Starts a **backend** Caddy on port 8081 that answers a fixed string over
   plain HTTP.
4. Starts the **proxy** Caddy on port 8443, which requests two certificates —
   one for a plain host (`vault.winkler.tel`) and one for a wildcard placed a
   level below it (`*.e2e.winkler.tel`).

   The wildcard is deliberately *not* `*.winkler.tel`. That would cover the
   plain host, Caddy would obtain a single certificate for both, and the
   non-wildcard path would silently go untested — which is exactly what an
   earlier version of this test did. The two names also exercise two different
   shapes in the provider: a single-label subdomain
   (`_acme-challenge.vault`) and a multi-label one (`_acme-challenge.e2e`).
5. Waits until each name serves the backend's answer over HTTPS.
6. Checks the certificate actually presented for each name: issued by the
   Let's Encrypt **staging** CA, and carrying the expected SAN.
7. Confirms the response body came from the backend, not from the proxy.

## Why no Docker

There is nothing to isolate. DNS-01 requires **no inbound connection** — that is
its entire point — so neither instance needs to be reachable from the internet,
and the test never binds a privileged port. Two processes prove exactly what two
containers would, and the same script then runs unchanged on a GitHub Actions
runner.

## Running it

```sh
EDNS_TOKEN=<your eDNS access token> ./run.sh
```

Locally, take the token from the development shell's `.env`:

```sh
EDNS_TOKEN=$(grep ^EDNS_TOKEN= ../../.env | cut -d= -f2) ./run.sh
```

Needs `go`, `xcaddy`, `openssl` and `curl` on `PATH`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `EDNS_TOKEN` | *(required)* | access token, assigned to the zone |
| `E2E_ZONE` | `winkler.tel` | zone to obtain certificates for |
| `E2E_HOST` | `vault.$E2E_ZONE` | the plain host to test |
| `E2E_WILDCARD` | `*.e2e.$E2E_ZONE` | the wildcard to test |
| `E2E_WILDCARD_HOST` | `probe.e2e.$E2E_ZONE` | a name only it covers |
| `E2E_CERT_TIMEOUT` | `900` | seconds to wait per certificate |

Changing `E2E_ZONE` also requires editing `Caddyfile.proxy`, which names the
zone directly — a Caddyfile cannot take the site address from an environment
variable.

The timeout is generous on purpose; see the note on the SOA minimum below.

## What it writes, and where

Challenge records are created in the **real zone**, at
`_acme-challenge.<host>` and `_acme-challenge.<zone>`. Caddy removes them again
after each challenge. Note that eDNS takes about five minutes to stop serving a
removed record (it appears to expire it with the 300 s TTL rather than push the
change), so a record may still be visible for a while after a successful run.
This is harmless: ACME accepts a challenge as long as *some* TXT record at the
name carries the expected value.

Everything else the run produces lands in `./run/` and is git-ignored, including
the ACME account key and the issued certificates.

## Why the first run is slow

`_acme-challenge.<host>` does not exist before the first issuance, so the first
lookup of it is answered with NXDOMAIN — cached for the zone's SOA minimum. Until
that expires, Caddy's propagation check cannot resolve the name's authoritative
servers and reports "not ready", even though eDNS published the record within
half a minute.

With `winkler.tel`'s SOA minimum at 300s, a measured run with a five-minute
`propagation_timeout` failed its first attempt at exactly 300s and succeeded 40s
into the retry. `Caddyfile.proxy` therefore uses ten minutes, so the first
attempt wins outright.

If the SOA minimum were still 86400, this would stall for a day, and no timeout
would help. Keep it low.

## Staging, not production

`Caddyfile.proxy` pins `acme_ca` to the Let's Encrypt **staging** endpoint. Its
certificates are signed by an untrusted root, which is why the test checks the
chain with `openssl` rather than relying on `curl` trusting it. Staging has far
looser rate limits — the production endpoint would lock you out after a handful
of failed attempts on the same names.

Do not point this at production to "test properly". If you want a production
certificate, configure Caddy normally; this script is for proving the module
works.
