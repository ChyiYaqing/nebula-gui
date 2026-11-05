package client

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/binary"
	"net"
	"net/netip"
	"sync"
	"time"

	"golang.org/x/net/icmp"
	"golang.org/x/net/ipv4"
	"golang.org/x/net/ipv6"
)

const maxSampleTargets = 64

type LatencySample struct {
	Address  string   `json:"address"`
	Measured bool     `json:"measured"`
	ReplyMS  *float64 `json:"replyMS,omitempty"`
}
type LatencyBatch struct {
	ObservedAt time.Time       `json:"observedAt"`
	Samples    []LatencySample `json:"samples"`
}

// sampleLatency measures every target once, all in parallel within one short shared
// deadline: requests to the backend are serial, so a batch must not delay user actions.
// A target whose socket could not be opened, or which ran out of time, is reported as
// not measured instead of as a lost reply.
func sampleLatency(targets []netip.Addr, networks []string, sample func(context.Context, string, netip.Addr) (ProbeResult, error)) LatencyBatch {
	ctx, cancel := context.WithTimeout(context.Background(), 1200*time.Millisecond)
	defer cancel()
	samples := make([]LatencySample, len(targets))
	var wait sync.WaitGroup
	for i, target := range targets {
		samples[i].Address = target.String()
		wait.Add(1)
		go func(i int, target netip.Addr) {
			defer wait.Done()
			local, _ := probeSource(target, networks)
			result, err := sample(ctx, target.String(), local)
			if err != nil || result.Sent == 0 {
				return
			}
			samples[i].Measured = true
			samples[i].ReplyMS = result.AverageMS
		}(i, target)
	}
	wait.Wait()
	return LatencyBatch{ObservedAt: time.Now().UTC(), Samples: samples}
}

type ProbeResult struct {
	Address    string    `json:"address"`
	Sent       int       `json:"sent"`
	Received   int       `json:"received"`
	AverageMS  *float64  `json:"averageMS,omitempty"`
	ObservedAt time.Time `json:"observedAt"`
}

func validateProbeTarget(text string, networks []string) (netip.Addr, error) {
	address, err := netip.ParseAddr(text)
	if err != nil || address.Zone() != "" {
		return netip.Addr{}, problem("invalid_target", "请输入 Nebula 节点的 IP 地址。", "address")
	}
	address = address.Unmap()
	if !address.IsGlobalUnicast() {
		return netip.Addr{}, problem("invalid_target", "只能测试 Nebula 网段内的单播地址。", "address")
	}
	allowed := false
	for _, text := range networks {
		prefix, err := netip.ParsePrefix(text)
		if err != nil {
			continue
		}
		if prefix.Addr().Unmap() == address {
			return netip.Addr{}, problem("invalid_target", "请输入其他节点的地址。", "address")
		}
		if prefix.Contains(address) {
			if address.Is4() && prefix.Bits() < 31 {
				octets := address.As4()
				host := binary.BigEndian.Uint32(octets[:]) & (^uint32(0) >> uint(prefix.Bits()))
				if host == 0 || host == (^uint32(0)>>uint(prefix.Bits())) {
					return netip.Addr{}, problem("invalid_target", "不能测试网段地址或广播地址。", "address")
				}
			}
			allowed = true
		}
	}
	if !allowed {
		return netip.Addr{}, problem("invalid_target", "目标不在当前网络证书声明的 Nebula 网段内。", "address")
	}
	return address, nil
}

// probeSource returns this device's address in the certificate network containing target.
func probeSource(target netip.Addr, networks []string) (netip.Addr, bool) {
	for _, text := range networks {
		if prefix, err := netip.ParsePrefix(text); err == nil && prefix.Contains(target) {
			return prefix.Addr().Unmap(), true
		}
	}
	return netip.Addr{}, false
}
func probeNode(ctx context.Context, target string, local netip.Addr) (ProbeResult, error) {
	conn, err := overlayProbeSocket(netip.MustParseAddr(target), local)
	if err != nil {
		return ProbeResult{}, err
	}
	defer conn.Close()
	return probeEcho(ctx, conn, target, time.Second, 3)
}

// sampleNode sends one echo; used by latency monitoring.
func sampleNode(ctx context.Context, target string, local netip.Addr) (ProbeResult, error) {
	conn, err := overlayProbeSocket(netip.MustParseAddr(target), local)
	if err != nil {
		return ProbeResult{}, err
	}
	defer conn.Close()
	return probeEcho(ctx, conn, target, time.Second, 1)
}
func probeEcho(ctx context.Context, conn net.PacketConn, target string, wait time.Duration, count int) (ProbeResult, error) {
	result := ProbeResult{Address: target}
	protocol, requestType, replyType := 1, icmp.Type(ipv4.ICMPTypeEcho), icmp.Type(ipv4.ICMPTypeEchoReply)
	if netip.MustParseAddr(target).Is6() {
		protocol, requestType, replyType = 58, ipv6.ICMPTypeEchoRequest, ipv6.ICMPTypeEchoReply
	}
	payload := make([]byte, 24)
	if _, err := rand.Read(payload); err != nil {
		return result, problem("probe_unavailable", "无法初始化节点探测。", "")
	}
	var total time.Duration
	buffer := make([]byte, 1500)
	for sequence := 1; sequence <= count; sequence++ {
		if ctx.Err() != nil {
			break
		}
		message, _ := (&icmp.Message{Type: requestType, Body: &icmp.Echo{ID: 1, Seq: sequence, Data: payload}}).Marshal(nil)
		deadline := time.Now().Add(wait)
		if end, ok := ctx.Deadline(); ok && end.Before(deadline) {
			deadline = end
		}
		if err := conn.SetDeadline(deadline); err != nil {
			return result, problem("probe_unavailable", "无法设置探测超时。", "")
		}
		started := time.Now()
		if _, err := conn.WriteTo(message, &net.UDPAddr{IP: net.ParseIP(target)}); err != nil {
			return result, problem("probe_unavailable", "探测请求未能发送，请检查网络。", "")
		}
		result.Sent++
		for {
			n, source, err := conn.ReadFrom(buffer)
			if err != nil {
				break
			}
			sourceIP, _, splitErr := net.SplitHostPort(source.String())
			if splitErr != nil {
				sourceIP = source.String()
			}
			remote, err := netip.ParseAddr(sourceIP)
			if err != nil || remote.Unmap() != netip.MustParseAddr(target).Unmap() {
				continue
			}
			response, err := icmp.ParseMessage(protocol, buffer[:n])
			if err != nil || response.Type != replyType {
				continue
			}
			echo, ok := response.Body.(*icmp.Echo)
			// Darwin may replace the identifier for unprivileged sockets; bind
			// the reply to the random payload, peer and sequence instead.
			if !ok || echo.Seq != sequence || !bytes.Equal(echo.Data, payload) {
				continue
			}
			result.Received++
			total += time.Since(started)
			break
		}
	}
	result.ObservedAt = time.Now().UTC()
	if result.Received > 0 {
		average := float64(total) / float64(time.Millisecond) / float64(result.Received)
		result.AverageMS = &average
	}
	return result, nil
}
