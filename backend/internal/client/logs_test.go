package client

import (
	"encoding/json"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/slackhq/nebula"
	"github.com/slackhq/nebula/config"
	"github.com/slackhq/nebula/logging"
)

const pemSample = "-----BEGIN NEBULA X25519 PRIVATE KEY-----\nAAAA\n-----END NEBULA X25519 PRIVATE KEY-----"

func field(e LogEntry, key string) (string, bool) {
	for _, f := range e.Fields {
		if f.Key == key {
			return f.Value, true
		}
	}
	return "", false
}

func TestRingHandlerKeepsOnlyAllowlistedFields(t *testing.T) {
	ring := &logRing{}
	l := slog.New(newRingHandler(ring)).With("certName", "laptop")
	l.Info("Handshake message sent",
		"vpnAddrs", []string{"10.1.0.2"}, "cert", pemSample, "packet", []byte{1, 2, 3},
		slog.Group("handshake", "stage", 1, "style", "ix_psk0", "raw", "x"),
		"error", "parse failed: "+pemSample)
	got := ring.since(0)
	if len(got) != 1 {
		t.Fatalf("entries = %d", len(got))
	}
	e := got[0]
	if e.Level != "info" || e.Message != "Handshake message sent" || e.Seq != 1 {
		t.Fatalf("unexpected entry %+v", e)
	}
	for key, want := range map[string]string{"certName": "laptop", "vpnAddrs": "[10.1.0.2]", "handshake.stage": "1", "handshake.style": "ix_psk0", "error": "[已隐藏]"} {
		if v, ok := field(e, key); !ok || v != want {
			t.Errorf("%s = %q, want %q", key, v, want)
		}
	}
	for _, key := range []string{"cert", "packet", "handshake.raw"} {
		if _, ok := field(e, key); ok {
			t.Errorf("disallowed field %s stored", key)
		}
	}
	if e.Hidden != 3 {
		t.Errorf("hidden = %d, want 3", e.Hidden)
	}
	raw, _ := json.Marshal(got)
	if strings.Contains(string(raw), "BEGIN") || strings.Contains(string(raw), "AAAA") {
		t.Fatal("key material leaked into captured logs")
	}
}

// Mirrors real handshake/relay logs from a 13.7.8 device: none of these fields may be hidden.
func TestRingHandlerShowsNebulaHandshakeAndRelayFields(t *testing.T) {
	ring := &logRing{}
	l := slog.New(newRingHandler(ring)).With("vpnAddrs", []string{"192.0.2.10"}, "localIndex", 1, "remoteIndex", 0)
	l.Info("Handshake timed out", "udpAddrs", []string{}, "initiatorIndex", 1, "durationNs", int64(5000000),
		"handshake", map[string]any{"style": "ix_psk0", "stage": uint64(1)})
	l.Info("Handshake message received", "from", "198.51.100.7:4242", "sentCachedPackets", 2)
	l.Info("handleCreateRelayResponse", "relayFrom", "192.0.2.12", "initiatorRelayIndex", 7, "responderRelayIndex", 9)
	l.Info("nested secret", "handshake", map[string]any{"stage": 1, "cert": pemSample})
	got := ring.since(0)
	for _, e := range got[:3] {
		if e.Hidden != 0 {
			t.Errorf("%q hid %d fields: %+v", e.Message, e.Hidden, e.Fields)
		}
	}
	if v, _ := field(got[0], "handshake.stage"); v != "1" {
		t.Errorf("handshake.stage = %q", v)
	}
	if v, _ := field(got[0], "handshake.style"); v != "ix_psk0" {
		t.Errorf("handshake.style = %q", v)
	}
	// Map keys outside the allowlist stay hidden, and their values are never formatted.
	if _, ok := field(got[3], "handshake.cert"); ok || got[3].Hidden != 1 {
		t.Fatalf("nested disallowed key leaked: %+v", got[3])
	}
	raw, _ := json.Marshal(got)
	if strings.Contains(string(raw), "BEGIN") {
		t.Fatal("nested map leaked key material")
	}
}

func TestRingHandlerLevelBoundsAndCapacity(t *testing.T) {
	ring := &logRing{}
	h := newRingHandler(ring)
	l := slog.New(h)
	l.Debug("hidden by default")
	if len(ring.since(0)) != 0 {
		t.Fatal("debug captured at default info level")
	}
	h.SetLevel(slog.LevelDebug)
	l.Debug(strings.Repeat("长", logMessageLimit+50), "error", strings.Repeat("x", logValueLimit+10)+"\nnext")
	e := ring.since(0)[0]
	if e.Level != "debug" || len([]rune(e.Message)) != logMessageLimit+1 || !strings.HasSuffix(e.Message, "…") {
		t.Fatalf("message not bounded: %d runes", len([]rune(e.Message)))
	}
	if v, _ := field(e, "error"); len([]rune(v)) != logValueLimit+1 || strings.Contains(v, "\n") {
		t.Fatalf("value not bounded: %q", v)
	}
	for i := 0; i < logRingCapacity+20; i++ {
		l.Warn("tick")
	}
	all := ring.since(0)
	if len(all) != logRingCapacity || all[len(all)-1].Seq != uint64(logRingCapacity+21) {
		t.Fatalf("ring holds %d, last seq %d", len(all), all[len(all)-1].Seq)
	}
	if tail := ring.since(all[len(all)-3].Seq); len(tail) != 2 {
		t.Fatalf("since returned %d", len(tail))
	}
}

func TestRelayedEntriesAreReboundedAndResequenced(t *testing.T) {
	ring := &logRing{}
	fields := []LogField{{"cert", pemSample}, {"udpAddr", "198.51.100.1:4242"}}
	for i := 0; i < logFieldLimit+2; i++ {
		fields = append(fields, LogField{"error", "e"})
	}
	ring.add(LogEntry{Seq: 99, Time: time.Now(), Level: "warning-long", Message: pemSample, Fields: fields})
	e := ring.since(0)[0]
	if e.Seq != 1 || e.Message != "[已隐藏]" || len(e.Fields) != logFieldLimit || e.Hidden != 4 || e.Level != "info" {
		t.Fatalf("relayed entry not re-bounded: %+v", e)
	}
	if _, ok := field(e, "cert"); ok {
		t.Fatal("relayed disallowed field kept")
	}
}

// The real kernel, in config-test mode, writes through the handler without key material.
func TestKernelLogsThroughRingHandlerWithoutSecrets(t *testing.T) {
	candidate, err := Inspect(fixture(t), "", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	c := config.NewC(logging.NewLogger(io.Discard))
	if err = c.LoadString(string(candidate.Config)); err != nil {
		t.Fatal(err)
	}
	ring := &logRing{}
	h := newRingHandler(ring)
	h.SetLevel(slog.LevelDebug)
	if _, err = nebula.Main(c, true, "nebula-gui-test", slog.New(h), nil); err != nil {
		t.Fatal(err)
	}
	got := ring.since(0)
	if len(got) == 0 {
		t.Fatal("kernel produced no captured logs")
	}
	raw, _ := json.Marshal(got)
	if strings.Contains(string(raw), "-----BEGIN") || strings.Contains(string(raw), "PRIVATE KEY") {
		t.Fatal("kernel log capture leaked PEM material")
	}
}

type loggingEngine struct {
	fakeEngine
	ring logRing
}

func (e *loggingEngine) LogsSince(after uint64) []LogEntry { return e.ring.since(after) }

func TestServiceLogsReportsAvailability(t *testing.T) {
	s := NewService(openStore(t), &fakeEngine{})
	page := request(s, "logs", "").Result.(LogPage)
	if page.Available || len(page.Entries) != 0 {
		t.Fatalf("engine without logs reported %+v", page)
	}
	engine := &loggingEngine{}
	engine.ring.add(LogEntry{Level: "info", Message: "Nebula interface is active"})
	s = NewService(openStore(t), engine)
	page = request(s, "logs", "").Result.(LogPage)
	if !page.Available || len(page.Entries) != 1 || page.Entries[0].Message != "Nebula interface is active" {
		t.Fatalf("logs page = %+v", page)
	}
	diag, _ := json.Marshal(request(s, "diagnostics", "").Result)
	if strings.Contains(string(diag), "Nebula interface is active") {
		t.Fatal("kernel logs included in diagnostics export")
	}
}
