package client

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// Kernel log capture keeps a bounded, redacted copy of Nebula's slog output.
// Only allowlisted attribute keys survive; everything else (certificates,
// packets, raw headers) is counted but never stored.
const (
	logRingCapacity = 300
	logMessageLimit = 300
	logValueLimit   = 200
	logFieldLimit   = 12
)

var logFieldAllowlist = map[string]bool{
	"error": true, "reason": true,
	"vpnAddr": true, "vpnAddrs": true, "udpAddr": true, "udpAddrs": true, "newAddr": true,
	"lighthouseAddr": true, "queryVpnAddr": true, "relay": true, "relayTo": true, "relayFrom": true,
	"certName": true, "fingerprint": true, "issuer": true, "certVersion": true,
	"initiatorIndex": true, "responderIndex": true, "remoteIndex": true, "localIndex": true,
	"handshake.stage": true, "handshake.style": true,
	"interface": true, "tun.dev": true, "mtu": true, "listen.port": true, "networks": true, "vpnNetworks": true,
	"route": true, "via": true, "version": true, "routines": true,
}

type LogField struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}
type LogEntry struct {
	Seq     uint64     `json:"seq"`
	Time    time.Time  `json:"time"`
	Level   string     `json:"level"`
	Message string     `json:"message"`
	Fields  []LogField `json:"fields"`
	Hidden  int        `json:"hidden,omitempty"`
}

// LogPage is the backend `logs` result. Available is false when the engine
// (for example an older helper) cannot supply kernel logs.
type LogPage struct {
	Available bool       `json:"available"`
	Entries   []LogEntry `json:"entries"`
}

type logRing struct {
	mu      sync.Mutex
	next    uint64
	entries []LogEntry
}

func (r *logRing) add(e LogEntry) {
	e = clampEntry(e)
	r.mu.Lock()
	defer r.mu.Unlock()
	r.next++
	e.Seq = r.next
	r.entries = append(r.entries, e)
	if len(r.entries) > logRingCapacity {
		r.entries = append([]LogEntry(nil), r.entries[len(r.entries)-logRingCapacity:]...)
	}
}

// since returns entries with Seq greater than after, oldest first.
func (r *logRing) since(after uint64) []LogEntry {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := []LogEntry{}
	for _, e := range r.entries {
		if e.Seq > after {
			out = append(out, e)
		}
	}
	return out
}

func clampText(s string, limit int) string {
	if strings.Contains(s, "-----BEGIN") || strings.Contains(strings.ToUpper(s), "PRIVATE KEY") {
		return "[已隐藏]"
	}
	s = strings.ToValidUTF8(strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\t' {
			return ' '
		}
		return r
	}, s), "")
	if utf8.RuneCountInString(s) <= limit {
		return s
	}
	return string([]rune(s)[:limit]) + "…"
}

// clampEntry re-applies every bound, so entries relayed from the helper are
// held to the same limits as ones captured in-process.
func clampEntry(e LogEntry) LogEntry {
	level := e.Level
	switch level {
	case "error", "warn", "info", "debug", "trace":
	default:
		level = "info"
	}
	out := LogEntry{Time: e.Time, Level: level, Message: clampText(e.Message, logMessageLimit), Hidden: e.Hidden, Fields: []LogField{}}
	for _, f := range e.Fields {
		if !logFieldAllowlist[f.Key] || len(out.Fields) >= logFieldLimit {
			out.Hidden++
			continue
		}
		out.Fields = append(out.Fields, LogField{f.Key, clampText(f.Value, logValueLimit)})
	}
	return out
}

// ringHandler is the slog.Handler handed to nebula.Main.
type ringHandler struct {
	ring   *logRing
	level  *slog.LevelVar
	group  string
	fields []LogField
}

func newRingHandler(ring *logRing) *ringHandler {
	return &ringHandler{ring: ring, level: new(slog.LevelVar)}
}

// SetLevel lets logging.ApplyConfig honour logging.level from the config.
func (h *ringHandler) SetLevel(l slog.Level) { h.level.Set(l) }
func (h *ringHandler) Enabled(_ context.Context, l slog.Level) bool {
	return l >= h.level.Level()
}
func (h *ringHandler) Handle(_ context.Context, r slog.Record) error {
	e := LogEntry{Time: r.Time.UTC(), Level: levelName(r.Level), Message: r.Message, Fields: append([]LogField(nil), h.fields...)}
	r.Attrs(func(a slog.Attr) bool { e.Fields = appendAttr(e.Fields, h.group, a); return true })
	h.ring.add(e)
	return nil
}
func (h *ringHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	c := *h
	c.fields = append([]LogField(nil), h.fields...)
	for _, a := range attrs {
		c.fields = appendAttr(c.fields, h.group, a)
	}
	return &c
}
func (h *ringHandler) WithGroup(name string) slog.Handler {
	if name == "" {
		return h
	}
	c := *h
	c.group = joinKey(h.group, name)
	return &c
}

func joinKey(group, key string) string {
	if group == "" {
		return key
	}
	return group + "." + key
}
func appendAttr(fields []LogField, group string, a slog.Attr) []LogField {
	v := a.Value.Resolve()
	if a.Key == "" && v.Kind() != slog.KindGroup {
		return fields
	}
	key := joinKey(group, a.Key)
	if v.Kind() == slog.KindGroup {
		if a.Key == "" {
			key = group
		}
		for _, sub := range v.Group() {
			fields = appendAttr(fields, key, sub)
		}
		return fields
	}
	// Formatting can be expensive (certificates, packets): skip disallowed keys first.
	if !logFieldAllowlist[key] {
		return append(fields, LogField{Key: key})
	}
	var s string
	if v.Kind() == slog.KindAny {
		s = fmt.Sprint(v.Any())
	} else {
		s = v.String()
	}
	return append(fields, LogField{key, s})
}
func levelName(l slog.Level) string {
	switch {
	case l >= slog.LevelError:
		return "error"
	case l >= slog.LevelWarn:
		return "warn"
	case l >= slog.LevelInfo:
		return "info"
	case l >= slog.LevelDebug:
		return "debug"
	default:
		return "trace"
	}
}
