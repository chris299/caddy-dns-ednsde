// Package ednsde registers the eDNS DNS-01 challenge provider as a Caddy DNS
// module, so that Caddy can obtain certificates for zones hosted at edns.de
// using the ACME DNS-01 challenge.
//
// Caddyfile:
//
//	tls {
//	    dns ednsde {env.EDNS_TOKEN}
//	}
//
// All of the actual work happens in github.com/chris299/libdns-ednsde; this
// package only registers the module and parses configuration.
package ednsde

import (
	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/caddyserver/certmagic"
	ednsdelib "github.com/chris299/libdns-ednsde"
)

func init() {
	caddy.RegisterModule(Provider{})
}

// Provider wraps the libdns eDNS provider as a Caddy module.
type Provider struct {
	*ednsdelib.Provider
}

// CaddyModule returns the Caddy module information.
func (Provider) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "dns.providers.ednsde",
		New: func() caddy.Module { return &Provider{new(ednsdelib.Provider)} },
	}
}

// Provision resolves Caddy placeholders in the token, which is what makes the
// usual idiom of keeping the credential out of the config file work:
//
//	dns ednsde {env.EDNS_TOKEN}
func (p *Provider) Provision(caddy.Context) error {
	repl := caddy.NewReplacer()
	p.Provider.APIToken = repl.ReplaceAll(p.Provider.APIToken, "")
	return nil
}

// UnmarshalCaddyfile parses the module's configuration:
//
//	ednsde [<api_token>] {
//	    api_token <api_token>
//	}
//
// The token may be given either as the argument or inside the block, but not
// both.
func (p *Provider) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {
	if p.Provider == nil {
		p.Provider = new(ednsdelib.Provider)
	}

	for d.Next() {
		if d.NextArg() {
			p.Provider.APIToken = d.Val()
		}
		if d.NextArg() {
			return d.ArgErr()
		}

		for nesting := d.Nesting(); d.NextBlock(nesting); {
			switch d.Val() {
			case "api_token":
				if p.Provider.APIToken != "" {
					return d.Err("api_token is already set by the argument on the same line")
				}
				if !d.NextArg() {
					return d.ArgErr()
				}
				p.Provider.APIToken = d.Val()
				if d.NextArg() {
					return d.ArgErr()
				}
			default:
				return d.Errf("unrecognized subdirective '%s'", d.Val())
			}
		}
	}

	if p.Provider.APIToken == "" {
		return d.Err("missing api_token")
	}
	return nil
}

var (
	_ caddyfile.Unmarshaler = (*Provider)(nil)
	_ caddy.Provisioner     = (*Provider)(nil)

	// Caddy hands DNS modules to CertMagic through this interface. Asserting it
	// here means a provider that cannot actually solve challenges fails to
	// compile, instead of failing when a certificate is first requested.
	_ certmagic.DNSProvider = (*Provider)(nil)
)
