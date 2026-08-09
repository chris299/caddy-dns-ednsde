package ednsde

import (
	"context"
	"strings"
	"testing"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
)

func newTestContext(t *testing.T) caddy.Context {
	t.Helper()
	ctx, cancel := caddy.NewContext(caddy.Context{Context: context.Background()})
	t.Cleanup(cancel)
	return ctx
}

func TestUnmarshalCaddyfile(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantTok string
		wantErr string
	}{
		{
			name:    "shorthand argument",
			input:   `ednsde TOKEN_ABC`,
			wantTok: "TOKEN_ABC",
		},
		{
			name: "block form",
			input: `ednsde {
				api_token TOKEN_ABC
			}`,
			wantTok: "TOKEN_ABC",
		},
		{
			name:    "no token at all",
			input:   `ednsde`,
			wantErr: "api_token",
		},
		{
			name:    "too many arguments",
			input:   `ednsde TOKEN_ABC TOKEN_DEF`,
			wantErr: "wrong argument count",
		},
		{
			// Specifying the token twice is always an error, even if both
			// values agree -- a config with two sources of truth for a
			// credential is a config waiting to drift.
			name: "token given both as argument and in the block",
			input: `ednsde TOKEN_ABC {
				api_token TOKEN_DEF
			}`,
			wantErr: "already set",
		},
		{
			name: "api_token without a value",
			input: `ednsde {
				api_token
			}`,
			wantErr: "wrong argument count",
		},
		{
			name: "unknown directive is rejected",
			input: `ednsde {
				endpoint https://example.invalid
			}`,
			wantErr: "unrecognized",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			d := caddyfile.NewTestDispenser(tc.input)
			p := &Provider{}

			err := p.UnmarshalCaddyfile(d)

			if tc.wantErr != "" {
				if err == nil {
					t.Fatalf("want an error containing %q, got nil", tc.wantErr)
				}
				if !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("want an error containing %q, got %q", tc.wantErr, err.Error())
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if p.Provider.APIToken != tc.wantTok {
				t.Errorf("want api_token %q, got %q", tc.wantTok, p.Provider.APIToken)
			}
		})
	}
}

// TestProvisionReplacesPlaceholders covers the usual Caddyfile idiom of keeping
// the token out of the config file: `dns ednsde {env.EDNS_TOKEN}`.
func TestProvisionReplacesPlaceholders(t *testing.T) {
	t.Setenv("EDNS_TOKEN_FOR_TEST", "TOKEN_FROM_ENV")

	d := caddyfile.NewTestDispenser(`ednsde {env.EDNS_TOKEN_FOR_TEST}`)
	p := &Provider{}
	if err := p.UnmarshalCaddyfile(d); err != nil {
		t.Fatalf("UnmarshalCaddyfile: %v", err)
	}
	if err := p.Provision(newTestContext(t)); err != nil {
		t.Fatalf("Provision: %v", err)
	}
	if p.Provider.APIToken != "TOKEN_FROM_ENV" {
		t.Errorf("want the placeholder replaced with the environment value, got %q", p.Provider.APIToken)
	}
}

func TestCaddyModuleID(t *testing.T) {
	id := string(Provider{}.CaddyModule().ID)
	if want := "dns.providers.ednsde"; id != want {
		t.Errorf("want module ID %q, got %q", want, id)
	}
}
