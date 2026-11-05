package client

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"
)

func startedService(t *testing.T) *Service {
	t.Helper()
	store := openStore(t)
	candidate, err := Inspect(fixture(t), "Latency", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	profile, err := store.Save(candidate, "")
	if err != nil {
		t.Fatal(err)
	}
	s := NewService(store, &fakeEngine{})
	t.Cleanup(func() { s.Close() })
	if r := request(s, "connect", profile.ID); r.Error != nil {
		t.Fatal(r.Error)
	}
	return s
}

func sampleRequest(s *Service, addresses ...string) Response {
	return s.Handle(Request{Version: 1, ID: "s", Method: "sample", Addresses: addresses})
}

func TestLatencySampleRejectsInvalidRequests(t *testing.T) {
	idle := NewService(openStore(t), &fakeEngine{})
	if r := sampleRequest(idle, "10.73.0.3"); r.Error == nil || r.Error.Code != "not_connected" {
		t.Fatal("sampled without a connection", r.Error)
	}
	s := startedService(t)
	s.sample = func(context.Context, string, netip.Addr) (ProbeResult, error) { return ProbeResult{Sent: 1}, nil }
	many := make([]string, maxSampleTargets+1)
	for i := range many {
		many[i] = fmt.Sprintf("10.73.0.%d", i+3)
	}
	for name, addresses := range map[string][]string{
		"empty":     nil,
		"too many":  many,
		"outside":   {"10.74.0.3"},
		"own":       {"10.73.0.2"},
		"duplicate": {"10.73.0.3", "10.73.0.3"},
	} {
		if r := sampleRequest(s, addresses...); r.Error == nil {
			t.Fatal(name, "accepted")
		}
	}
	if r := sampleRequest(s, "10.73.0.3"); r.Error != nil {
		t.Fatal(r.Error)
	}
	if r := sampleRequest(s, "10.73.0.3"); r.Error == nil || r.Error.Code != "probe_rate_limited" {
		t.Fatal("rate limit missing", r.Error)
	}
}

func TestLatencySampleReportsEachAddress(t *testing.T) {
	s := startedService(t)
	var calls atomic.Int32
	s.sample = func(_ context.Context, target string, local netip.Addr) (ProbeResult, error) {
		calls.Add(1)
		if local.String() != "10.73.0.2" {
			t.Error("wrong source", local)
		}
		switch target {
		case "10.73.0.3":
			ms := 12.5
			return ProbeResult{Sent: 1, Received: 1, AverageMS: &ms}, nil
		case "10.73.0.4":
			return ProbeResult{Sent: 1}, nil
		}
		return ProbeResult{}, errors.New("socket unavailable")
	}
	r := sampleRequest(s, "10.73.0.3", "10.73.0.4", "10.73.0.5")
	if r.Error != nil {
		t.Fatal(r.Error)
	}
	batch := r.Result.(LatencyBatch)
	if calls.Load() != 3 || len(batch.Samples) != 3 {
		t.Fatal(batch)
	}
	replied, lost, failed := batch.Samples[0], batch.Samples[1], batch.Samples[2]
	if replied.Address != "10.73.0.3" || !replied.Measured || replied.ReplyMS == nil || *replied.ReplyMS != 12.5 {
		t.Fatal("reply", replied)
	}
	if lost.Address != "10.73.0.4" || !lost.Measured || lost.ReplyMS != nil {
		t.Fatal("lost", lost)
	}
	if failed.Address != "10.73.0.5" || failed.Measured || failed.ReplyMS != nil {
		t.Fatal("unmeasured reported as loss", failed)
	}
}

func TestLatencySampleSharesOneShortDeadline(t *testing.T) {
	targets := make([]netip.Addr, maxSampleTargets)
	for i := range targets {
		targets[i] = netip.MustParseAddr(fmt.Sprintf("10.73.0.%d", i+3))
	}
	started := time.Now()
	batch := sampleLatency(targets, []string{"10.73.0.2/24"}, func(ctx context.Context, _ string, _ netip.Addr) (ProbeResult, error) {
		<-ctx.Done() // nodes that never answer must not hold the serial backend past the batch deadline
		return ProbeResult{Sent: 1}, nil
	})
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatal("batch exceeded its deadline", elapsed)
	}
	for _, sample := range batch.Samples {
		if !sample.Measured || sample.ReplyMS != nil {
			t.Fatal("silent node must be a measured loss", sample)
		}
	}
}
