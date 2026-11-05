package client

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"go.yaml.in/yaml/v3"
)

// inlineFixture embeds the fixture's credentials, as the backend does before sending to the helper.
func inlineFixture(t *testing.T, path string) []byte {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err = yaml.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	pki := m["pki"].(map[string]any)
	for _, role := range []string{"ca", "cert", "key"} {
		data, err := os.ReadFile(filepath.Join(filepath.Dir(path), pki[role].(string)))
		if err != nil {
			t.Fatal(err)
		}
		pki[role] = string(data)
	}
	out, err := yaml.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return out
}

// The kernel installs a system route for every certificate network, and the helper
// accepts caller-supplied CAs. Only non-public ranges may therefore reach the routing table.
func TestCertificateNetworksMustStayInNonPublicRanges(t *testing.T) {
	for _, tc := range []struct {
		networks []string
		allowed  bool
	}{
		{[]string{"10.73.0.2/24"}, true},
		{[]string{"172.16.5.2/12"}, true},
		{[]string{"192.168.100.2/24"}, true},
		{[]string{"100.64.1.2/16"}, true},
		{[]string{"10.73.0.2/24", "fd00:1::2/64"}, true},
		{[]string{"1.0.0.1/1", "128.0.0.1/1"}, false}, // Together they cover all of IPv4.
		{[]string{"10.73.0.2/24", "8.8.8.2/24"}, false},
		{[]string{"10.73.0.2/7"}, false}, // Wider than 10.0.0.0/8.
		{[]string{"2001:db8::2/64"}, false},
	} {
		t.Run(tc.networks[0], func(t *testing.T) {
			path := fixtureNetworks(t, t.TempDir(), time.Now().Add(24*time.Hour), tc.networks...)
			_, imported := Inspect(path, "", nil, time.Now())
			_, inline := validateInline(inlineFixture(t, path), t.TempDir())
			for name, err := range map[string]error{"import": imported, "helper": inline} {
				if tc.allowed {
					if err != nil {
						t.Fatalf("%s rejected %v: %v", name, tc.networks, err)
					}
					continue
				}
				var p *Problem
				if !errors.As(err, &p) || p.Code != "unsupported" || p.Field != "pki.cert" {
					t.Fatalf("%s accepted or misreported %v: %v", name, tc.networks, err)
				}
			}
		})
	}
}
