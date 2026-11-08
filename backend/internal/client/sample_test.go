package client

import (
	"context"
	"fmt"
	"net/netip"
	"sync"
	"testing"
	"time"
)

func startedSampleService(t *testing.T) *Service {
	t.Helper()
	store := openStore(t)
	candidate, err := Inspect(fixture(t), "", nil, time.Now()) // network 10.73.0.2/24
	if err != nil {
		t.Fatal(err)
	}
	saved, err := store.Save(candidate, "")
	if err != nil {
		t.Fatal(err)
	}
	s := NewService(store, &fakeEngine{})
	t.Cleanup(func() { s.Close() })
	if r := request(s, "connect", saved.ID); r.Error != nil {
		t.Fatal(r.Error)
	}
	return s
}

func sampleRequest(s *Service, addresses ...string) Response {
	return s.Handle(Request{Version: 1, ID: "sample", Method: "sample", Addresses: addresses})
}

func TestSampleRejectsOutOfContractRequests(t *testing.T) {
	idle := NewService(openStore(t), &fakeEngine{})
	if r := sampleRequest(idle, "10.73.0.3"); r.Error == nil || r.Error.Code != "not_connected" {
		t.Fatalf("not connected: %+v", r.Error)
	}
	s := startedSampleService(t)
	s.sampleOne = func(context.Context, string, netip.Addr) LatencySample { return LatencySample{Status: "timeout"} }
	tooMany := make([]string, maxSampleTargets+1)
	for i := range tooMany {
		tooMany[i] = fmt.Sprintf("10.73.0.%d", i+3)
	}
	for name, c := range map[string]struct {
		addresses []string
		code      string
	}{
		"empty":       {nil, "invalid_target"},
		"too many":    {tooMany, "too_many_targets"},
		"out of net":  {[]string{"10.73.0.3", "192.0.2.10"}, "invalid_target"},
		"self":        {[]string{"10.73.0.2"}, "invalid_target"},
		"broadcast":   {[]string{"10.73.0.255"}, "invalid_target"},
		"not an addr": {[]string{"example.com"}, "invalid_target"},
	} {
		if r := sampleRequest(s, c.addresses...); r.Error == nil || r.Error.Code != c.code {
			t.Errorf("%s: got %+v, want %s", name, r.Error, c.code)
		}
	}
	if !s.lastSample.IsZero() {
		t.Fatal("rejected requests must not consume the rate limit")
	}
	if r := sampleRequest(s, "10.73.0.3"); r.Error != nil {
		t.Fatal(r.Error)
	}
	if r := sampleRequest(s, "10.73.0.3"); r.Error == nil || r.Error.Code != "sample_rate_limited" {
		t.Fatalf("second round within %s: %+v", sampleMinimumSpacing, r.Error)
	}
}

func TestDecodeRequestBoundsAddresses(t *testing.T) {
	if _, err := DecodeRequest([]byte(`{"version":1,"id":"x","method":"sample","addresses":["10.73.0.3"]}`)); err != nil {
		t.Fatal(err)
	}
	long := `{"version":1,"id":"x","method":"sample","addresses":["` + fmt.Sprintf("%065d", 0) + `"]}`
	if _, err := DecodeRequest([]byte(long)); err == nil {
		t.Fatal("accepted an over-long address")
	}
}

func TestSampleReturnsPerAddressResultsInOrderWithBoundedConcurrency(t *testing.T) {
	s := startedSampleService(t)
	var mu sync.Mutex
	active, peak := 0, 0
	s.sampleOne = func(_ context.Context, target string, local netip.Addr) LatencySample {
		mu.Lock()
		active++
		if active > peak {
			peak = active
		}
		mu.Unlock()
		time.Sleep(20 * time.Millisecond)
		mu.Lock()
		active--
		mu.Unlock()
		if local != netip.MustParseAddr("10.73.0.2") {
			return LatencySample{Status: "unavailable"}
		}
		if target == "10.73.0.4" {
			return LatencySample{Status: "timeout"}
		}
		ms := 12.5
		return LatencySample{Status: "reply", LatencyMS: &ms}
	}
	addresses := []string{"10.73.0.4", "10.73.0.3", "10.73.0.3"} // duplicate collapses
	for i := 5; i < 25; i++ {
		addresses = append(addresses, fmt.Sprintf("10.73.0.%d", i))
	}
	r := sampleRequest(s, addresses...)
	if r.Error != nil {
		t.Fatal(r.Error)
	}
	round := r.Result.(SampleRound)
	if len(round.Samples) != 22 || round.ObservedAt.IsZero() {
		t.Fatalf("samples = %d", len(round.Samples))
	}
	if round.Samples[0].Address != "10.73.0.4" || round.Samples[0].Status != "timeout" || round.Samples[0].LatencyMS != nil {
		t.Fatalf("first = %+v", round.Samples[0])
	}
	if round.Samples[1].Address != "10.73.0.3" || round.Samples[1].Status != "reply" || *round.Samples[1].LatencyMS != 12.5 {
		t.Fatalf("second = %+v", round.Samples[1])
	}
	if peak > sampleConcurrency || peak < 2 {
		t.Fatalf("peak concurrency %d, limit %d", peak, sampleConcurrency)
	}
}

func TestSampleRoundLimitMarksRemainingUnmeasured(t *testing.T) {
	s := startedSampleService(t)
	s.sampleOne = func(ctx context.Context, _ string, _ netip.Addr) LatencySample {
		<-ctx.Done() // Every target hangs until the round limit.
		return LatencySample{Status: "timeout"}
	}
	addresses := []string{}
	for i := 3; i < 3+sampleConcurrency+4; i++ {
		addresses = append(addresses, fmt.Sprintf("10.73.0.%d", i))
	}
	started := time.Now()
	r := sampleRequest(s, addresses...)
	if elapsed := time.Since(started); elapsed > sampleRoundLimit+time.Second {
		t.Fatalf("round took %s", elapsed)
	}
	unmeasured := 0
	for _, sample := range r.Result.(SampleRound).Samples {
		if sample.Status == "unmeasured" {
			unmeasured++
		}
	}
	if unmeasured != 4 {
		t.Fatalf("unmeasured = %d, want the 4 targets that never got a slot", unmeasured)
	}
}
