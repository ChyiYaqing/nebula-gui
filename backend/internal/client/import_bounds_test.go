package client

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Unknown keys may be pasted credentials; only field-like names are reported back.
func TestUnknownKeysAreReportedOnlyAsFieldNames(t *testing.T) {
	secret := "-----BEGIN NEBULA X25519 PRIVATE KEY-----\nAAAA\n-----END NEBULA X25519 PRIVATE KEY-----"
	for raw, want := range map[string]string{
		"plain_extra: 1\n":                              "plain_extra",
		fmt.Sprintf("%q: 1\n", secret):                  "config",
		"pki: {extra_option: 1}\n":                      "pki.extra_option",
		fmt.Sprintf("pki: {%q: 1}\n", secret):           "pki",
		fmt.Sprintf("%q: 1\n", strings.Repeat("a", 65)): "config",
	} {
		m, err := parseConfig([]byte(raw))
		if err != nil {
			t.Fatal(err)
		}
		err = validatePolicy(m)
		var p *Problem
		if !errors.As(err, &p) || p.Code != "unsupported" || p.Field != want {
			t.Fatalf("%q: want field %q, got %v", raw, want, err)
		}
		if b, _ := json.Marshal(p); strings.Contains(string(b), "BEGIN") {
			t.Fatalf("credential text echoed: %s", b)
		}
	}
}

// Decoding a YAML mapping checks duplicate keys pairwise, so object size is bounded first.
func TestOversizedYAMLObjectsAreRejectedBeforeDecoding(t *testing.T) {
	object := func(n int) []byte {
		var b strings.Builder
		for i := 0; i < n; i++ {
			fmt.Fprintf(&b, "k%d: 0\n", i)
		}
		return []byte(b.String())
	}
	if _, err := parseConfig(object(maxMappingEntries)); err != nil {
		t.Fatalf("rejected an object at the limit: %v", err)
	}
	_, err := parseConfig(object(maxMappingEntries + 1))
	code(t, err, "invalid_yaml")
	big := object(200000) // About 2 MiB: previously close to a minute of key comparisons.
	if len(big) > maxFileSize {
		t.Fatal("fixture exceeds the input limit")
	}
	started := time.Now()
	_, err = parseConfig(big)
	code(t, err, "invalid_yaml")
	if elapsed := time.Since(started); elapsed > 5*time.Second {
		t.Fatalf("bounded rejection took %v", elapsed)
	}
}

// Embedding credentials and re-indenting can outgrow the limit Load reads with.
func TestManagedCopyMustFitTheReadLimit(t *testing.T) {
	path := fixture(t)
	caPath := filepath.Join(filepath.Dir(path), "ca.cert")
	ca, err := os.ReadFile(caPath)
	if err != nil {
		t.Fatal(err)
	}
	repeated := []byte{}
	for len(repeated)+len(ca) <= maxFileSize-4096 {
		repeated = append(repeated, ca...)
	}
	if err = os.WriteFile(caPath, repeated, 0600); err != nil {
		t.Fatal(err)
	}
	_, err = Inspect(path, "", nil, time.Now())
	code(t, err, "config_too_large")
}
