package client

import (
	"context"
	"net/netip"
	"testing"
)

func TestProbeSourceIsTheLocalAddressOfTheMatchingNetwork(t *testing.T) {
	networks := []string{"10.73.0.2/24", "fd00:1::2/64"}
	for target, want := range map[string]string{"10.73.0.9": "10.73.0.2", "fd00:1::9": "fd00:1::2"} {
		got, ok := probeSource(netip.MustParseAddr(target), networks)
		if !ok || got != netip.MustParseAddr(want) {
			t.Fatalf("%s: got %v %v", target, got, ok)
		}
	}
	if _, ok := probeSource(netip.MustParseAddr("192.168.1.9"), networks); ok {
		t.Fatal("matched a target outside every network")
	}
}

// An address held by no interface must not fall back to the system routing
// table. Sending through a bound interface is covered by TestUnprivilegedICMPLoopback.
func TestProbeWithoutTheLocalInterfaceIsUnavailable(t *testing.T) {
	if sample := sampleNode(context.Background(), "127.0.0.1", netip.MustParseAddr("10.255.255.254")); sample.Status != "unavailable" {
		t.Fatalf("sample without the Nebula interface = %+v", sample)
	}
}
