package client

import (
	"context"
	"net"
	"net/netip"
	"os"
	"testing"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
)

func TestProbeTargetScope(t *testing.T) {
	networks := []string{"10.73.0.2/24", "fd00:73::2/64"}
	for _, address := range []string{"10.73.0.3", "fd00:73::3"} {
		if _, err := validateProbeTarget(address, networks); err != nil {
			t.Fatal(err)
		}
	}
	for _, address := range []string{"10.73.0.2", "fd00:73::2", "10.74.0.3", "127.0.0.1", "::1", "224.0.0.1", "255.255.255.255", "10.73.0.255", "10.73.0.0", "example.com", "10.73.0.3;echo", "fd00:73::3%en0"} {
		if _, err := validateProbeTarget(address, networks); err == nil {
			t.Fatalf("accepted invalid target %s", address)
		}
	}
}

type echoPacket struct {
	body   []byte
	source net.Addr
}
type fakeEchoSocket struct {
	packets  []echoPacket
	writes   int
	mismatch bool
}

func (s *fakeEchoSocket) WriteTo(data []byte, address net.Addr) (int, error) {
	s.writes++
	if s.writes == 3 {
		return len(data), nil
	} // One deliberate loss.
	request, _ := icmp.ParseMessage(1, data)
	echo := request.Body.(*icmp.Echo)
	// Wrong payload and wrong source must not count as replies.
	bad, _ := (&icmp.Message{Type: ipv4.ICMPTypeEchoReply, Body: &icmp.Echo{Seq: echo.Seq, Data: []byte("wrong")}}).Marshal(nil)
	good, _ := (&icmp.Message{Type: ipv4.ICMPTypeEchoReply, Body: &icmp.Echo{ID: 999, Seq: echo.Seq, Data: echo.Data}}).Marshal(nil)
	s.packets = append(s.packets, echoPacket{bad, address}, echoPacket{good, &net.IPAddr{IP: net.ParseIP("10.73.0.99")}})
	if !s.mismatch {
		s.packets = append(s.packets, echoPacket{good, address})
	}
	return len(data), nil
}
func (s *fakeEchoSocket) ReadFrom(buffer []byte) (int, net.Addr, error) {
	if len(s.packets) == 0 {
		return 0, nil, &net.DNSError{IsTimeout: true}
	}
	packet := s.packets[0]
	s.packets = s.packets[1:]
	return copy(buffer, packet.body), packet.source, nil
}
func (*fakeEchoSocket) Close() error                     { return nil }
func (*fakeEchoSocket) LocalAddr() net.Addr              { return &net.IPAddr{} }
func (*fakeEchoSocket) SetDeadline(time.Time) error      { return nil }
func (*fakeEchoSocket) SetReadDeadline(time.Time) error  { return nil }
func (*fakeEchoSocket) SetWriteDeadline(time.Time) error { return nil }
func TestProbeMatchesPeerNonceSequenceAndReportsLoss(t *testing.T) {
	for _, mismatch := range []bool{false, true} {
		result, err := probeEcho(context.Background(), &fakeEchoSocket{mismatch: mismatch}, "10.73.0.3", time.Millisecond, 3)
		if err != nil {
			t.Fatal(err)
		}
		if result.Sent != 3 {
			t.Fatal(result)
		}
		if mismatch {
			if result.Received != 0 || result.AverageMS != nil {
				t.Fatal("forged replies counted", result)
			}
		} else if result.Received != 2 || result.AverageMS == nil || result.ObservedAt.IsZero() {
			t.Fatal(result)
		}
	}
}
func TestUnprivilegedICMPLoopback(t *testing.T) {
	if os.Getenv("NEBULA_GUI_ICMP_TEST") != "1" {
		t.Skip("explicitly enable ordinary-user loopback probe")
	}
	for _, target := range []string{"127.0.0.1", "::1"} {
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		// Loopback stands in for the utun holding this device's Nebula address.
		sample := sampleNode(ctx, target, netip.MustParseAddr(target))
		cancel()
		if sample.Status != "reply" || sample.LatencyMS == nil {
			t.Fatalf("%s: %+v", target, sample)
		}
	}
}
