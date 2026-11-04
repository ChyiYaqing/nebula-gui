package client

import "testing"

func TestRuntimeTimingBoundsBeforeKernelValidation(t *testing.T) {
	for _, raw := range []string{
		"handshakes: {try_interval: '-1s'}",
		"handshakes: {try_interval: '0s'}",
		"handshakes: {try_interval: '1ns'}",
		"handshakes: {try_interval: '2m'}",
		"handshakes: {try_interval: 1}",
		"lighthouse: {interval: -1}",
		"lighthouse: {interval: 9223372036854775807}",
		"firewall: {conntrack: {routine_cache_timeout: '-1s'}}",
		"firewall: {conntrack: {routine_cache_timeout: '1ns'}}",
		"firewall: {conntrack: {tcp_timeout: '1ns'}}",
		"firewall: {conntrack: {udp_timeout: '0s'}}",
		"firewall: {conntrack: {default_timeout: '100000h'}}",
		"firewall: {conntrack: {tcp_timeout: 'bad'}}",
		"firewall: {conntrack: {tcp_timeout: '1ms'}}", // Defaults also participate in the wheel size.
		"firewall: {conntrack: {tcp_timeout: '65535s', udp_timeout: '1s', default_timeout: '1s'}}",
	} {
		t.Run(raw, func(t *testing.T) {
			m, err := parseConfig([]byte(raw))
			if err != nil {
				t.Fatal(err)
			}
			code(t, validatePolicy(m), "unsupported")
			// No credentials are supplied: timing must be rejected before Inspect or kernel allocation.
			_, err = validateInline([]byte(raw), t.TempDir())
			code(t, err, "unsupported")
		})
	}
	for _, raw := range []string{
		"{}",
		"handshakes: {try_interval: '10ms'}",
		"handshakes: {try_interval: '1m'}",
		"lighthouse: {interval: 0}",
		"lighthouse: {interval: 86400}",
		"firewall: {conntrack: {routine_cache_timeout: '0s'}}",
		"firewall: {conntrack: {routine_cache_timeout: '10ms'}}",
		"firewall: {conntrack: {tcp_timeout: '65534s', udp_timeout: '1s', default_timeout: '1s'}}",
	} {
		m, err := parseConfig([]byte(raw))
		if err != nil {
			t.Fatal(err)
		}
		if err = validatePolicy(m); err != nil {
			t.Fatalf("valid boundary %s: %v", raw, err)
		}
	}
}
