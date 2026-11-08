package client

import (
	"context"
	"net/netip"
	"sync"
	"time"
)

// Periodic latency monitoring (#44): one ICMP echo per active peer address,
// requested by the GUI every few seconds while the nodes page is visible.
// It runs in the ordinary backend only, never in the root helper.
const (
	maxSampleTargets     = 64
	sampleConcurrency    = 8
	sampleWait           = time.Second
	sampleRoundLimit     = 4 * time.Second
	sampleMinimumSpacing = 2 * time.Second
)

type LatencySample struct {
	Address   string   `json:"address"`
	Status    string   `json:"status"` // reply, timeout (no ICMP reply), unavailable, unmeasured
	LatencyMS *float64 `json:"latencyMS,omitempty"`
}
type SampleRound struct {
	ObservedAt time.Time       `json:"observedAt"`
	Samples    []LatencySample `json:"samples"`
}

func (s *Service) sample(addresses []string) (any, error) {
	if s.status().State != "started" {
		return nil, problem("not_connected", "请先连接网络，再监测节点延迟。", "")
	}
	if len(addresses) == 0 {
		return nil, problem("invalid_target", "没有可监测的节点地址。", "addresses")
	}
	if len(addresses) > maxSampleTargets {
		return nil, problem("too_many_targets", "一次最多监测 64 个节点地址。", "addresses")
	}
	profile, _, err := s.store.Load(s.active)
	if err != nil {
		return nil, err
	}
	targets := make([]netip.Addr, 0, len(addresses))
	seen := map[netip.Addr]bool{}
	for _, text := range addresses {
		address, err := validateProbeTarget(text, profile.Networks)
		if err != nil {
			return nil, err
		}
		if !seen[address] {
			seen[address] = true
			targets = append(targets, address)
		}
	}
	if time.Since(s.lastSample) < sampleMinimumSpacing {
		return nil, problem("sample_rate_limited", "节点延迟采样过于频繁。", "")
	}
	s.lastSample = time.Now()
	one := s.sampleOne
	if one == nil {
		one = sampleNode
	}
	ctx, cancel := context.WithTimeout(context.Background(), sampleRoundLimit)
	defer cancel()
	samples := make([]LatencySample, len(targets))
	slots := make(chan struct{}, sampleConcurrency)
	var wg sync.WaitGroup
	for i, target := range targets {
		samples[i] = LatencySample{Address: target.String(), Status: "unmeasured"}
		local, _ := probeSource(target, profile.Networks) // validateProbeTarget found the network.
		wg.Add(1)
		go func(i int, target, local netip.Addr) {
			defer wg.Done()
			select {
			case slots <- struct{}{}:
			case <-ctx.Done():
				return // Round limit reached before this target got a slot.
			}
			defer func() { <-slots }()
			if ctx.Err() == nil {
				samples[i] = one(ctx, target.String(), local)
				samples[i].Address = target.String()
			}
		}(i, target, local)
	}
	wg.Wait()
	return SampleRound{ObservedAt: time.Now().UTC(), Samples: samples}, nil
}

func sampleNode(ctx context.Context, target string, local netip.Addr) LatencySample {
	sample := LatencySample{Address: target, Status: "unavailable"}
	conn, err := overlayProbeSocket(netip.MustParseAddr(target), local)
	if err != nil {
		return sample
	}
	defer conn.Close()
	result, err := probeEcho(ctx, conn, target, sampleWait, 1)
	switch {
	case err != nil:
	case result.Received == 1 && result.AverageMS != nil:
		sample.Status, sample.LatencyMS = "reply", result.AverageMS
	default:
		sample.Status = "timeout"
	}
	return sample
}
