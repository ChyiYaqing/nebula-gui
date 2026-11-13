package client

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestFirewallUnknownRuleKeys(t *testing.T) {
	const secret = "-----BEGIN NEBULA X25519 PRIVATE KEY-----"
	for _, direction := range []string{"inbound", "outbound"} {
		for _, key := range []string{"ca_shaa", secret} {
			t.Run(direction+"/"+key, func(t *testing.T) {
				path := fixture(t)
				changeYAML(t, path, func(m map[string]any) {
					section(m, "firewall")[direction].([]any)[0].(map[string]any)[key] = secret
				})
				_, imported := Inspect(path, "", nil, time.Now())
				_, inline := validateInline(inlineFixture(t, path), t.TempDir())
				for _, err := range []error{imported, inline} {
					code(t, err, "unsupported")
					want := "firewall." + direction
					if key == "ca_shaa" {
						want += ".ca_shaa"
					}
					if err.(*Problem).Field != want {
						t.Fatalf("want field %s, got %+v", want, err)
					}
					b, _ := json.Marshal(err)
					if strings.Contains(string(b), secret) || strings.Contains(err.Error(), secret) {
						t.Fatal("rule key or value leaked")
					}
				}
			})
		}
	}
}

func TestFirewallAllowedRuleKeys(t *testing.T) {
	path := fixture(t)
	changeYAML(t, path, func(m map[string]any) {
		rules := []any{
			map[string]any{"port": "any", "proto": "any", "host": "any"},
			map[string]any{"port": 443, "proto": "tcp", "group": "test"},
			map[string]any{"port": "443", "proto": "tcp", "groups": []any{"test", "other"}},
			map[string]any{"port": "80-82", "proto": "udp", "cidr": "10.73.0.0/24"},
			map[string]any{"port": "fragment", "proto": "any", "local_cidr": "10.73.0.0/24"},
			map[string]any{"port": "any", "proto": "any", "ca_name": "Temporary Test CA"},
			map[string]any{"port": "any", "proto": "any", "ca_sha": strings.Repeat("a", 64)},
			map[string]any{"code": 8, "proto": "icmp", "host": "any"},
		}
		m["firewall"] = map[string]any{"inbound": rules, "outbound": rules}
	})
	if _, err := Inspect(path, "", nil, time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := validateInline(inlineFixture(t, path), t.TempDir()); err != nil {
		t.Fatal(err)
	}
}

func TestFirewallPortExpansionBudget(t *testing.T) {
	for _, count := range []int{2, 3} {
		t.Run(fmt.Sprint(count), func(t *testing.T) {
			path := fixture(t)
			changeYAML(t, path, func(m map[string]any) {
				var rules []any
				for i := 0; i < count; i++ {
					rules = append(rules, map[string]any{"port": "1-65535", "proto": "tcp", "ca_name": fmt.Sprint(i)})
				}
				m["firewall"] = map[string]any{"inbound": rules[:1], "outbound": rules[1:]}
			})
			started := time.Now()
			_, err := Inspect(path, "", nil, time.Now())
			elapsed := time.Since(started)
			if count == 2 {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			code(t, err, "unsupported")
			if err.(*Problem).Field != "firewall" {
				t.Fatalf("wrong field: %+v", err)
			}
			if elapsed >= 500*time.Millisecond {
				t.Fatalf("budget rejection took %v", elapsed)
			}
			_, err = validateInline(inlineFixture(t, path), t.TempDir())
			code(t, err, "unsupported")
		})
	}
}

func TestFirewallPortBudgetBoundary(t *testing.T) {
	rules := []any{map[string]any{"port": "0-65535"}, map[string]any{"port": " 0 - 65535 "}}
	m := map[string]any{"firewall": map[string]any{"inbound": rules}}
	if err := validatePolicy(m); err != nil {
		t.Fatal(err)
	}
	for _, port := range []any{nil, "", "any", "fragment", 443, "443", "bad", "-1-65535", "0-65536", "2-1", "1-2-3"} {
		section(m, "firewall")["outbound"] = []any{map[string]any{"port": port}}
		code(t, validatePolicy(m), "unsupported")
	}
}

func TestFirewallRuleShapes(t *testing.T) {
	for _, direction := range []string{"inbound", "outbound"} {
		for _, value := range []any{"not a list", []any{"not a mapping"}, []any{nil}, []any{map[any]any{1: "bad"}}} {
			path := fixture(t)
			changeYAML(t, path, func(m map[string]any) { section(m, "firewall")[direction] = value })
			_, err := Inspect(path, "", nil, time.Now())
			code(t, err, "invalid_config")
		}
	}
	for _, value := range []any{nil, []any{}} {
		path := fixture(t)
		changeYAML(t, path, func(m map[string]any) { m["firewall"] = map[string]any{"inbound": value} })
		if _, err := Inspect(path, "", nil, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
}

func TestImportAndHelperSharePolicyBounds(t *testing.T) {
	for field, edit := range map[string]func(map[string]any){
		"routines":     func(m map[string]any) { m["routines"] = 0 },
		"tun.tx_queue": func(m map[string]any) { section(m, "tun")["tx_queue"] = 0 },
		"dns":          func(m map[string]any) { m["dns"] = map[string]any{"enabled": false, "host": "1.2.3.4"} },
	} {
		t.Run(field, func(t *testing.T) {
			path := fixture(t)
			changeYAML(t, path, edit)
			_, imported := Inspect(path, "", nil, time.Now())
			_, inline := validateInline(inlineFixture(t, path), t.TempDir())
			for _, err := range []error{imported, inline} {
				code(t, err, "unsupported")
				if err.(*Problem).Field != field {
					t.Fatalf("want field %s, got %+v", field, err)
				}
			}
		})
	}
}
