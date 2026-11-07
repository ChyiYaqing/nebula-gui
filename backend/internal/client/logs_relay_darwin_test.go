package client

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// relayEngine logs during Start and on every status poll, like the kernel does.
type relayEngine struct {
	loggingEngine
	failStart bool
}

func (e *relayEngine) Start([]byte) error {
	e.ring.add(LogEntry{Level: "info", Message: "starting"})
	if e.failStart {
		e.ring.add(LogEntry{Level: "error", Message: "Failed to get a tun/tap device", Fields: []LogField{{"error", "operation not permitted"}}})
		return problem("start_failed", "Nebula 无法启动。", "")
	}
	e.alive = true
	return nil
}
func (e *relayEngine) Alive() bool {
	e.ring.add(LogEntry{Level: "debug", Message: "poll"})
	return e.alive
}

func relayHelper(t *testing.T, failStart bool) string {
	t.Helper()
	root, err := os.MkdirTemp("/private/tmp", "ng-l-")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "h.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	server := &HelperServer{AllowedUID: uint32(os.Geteuid()), TemporaryRoot: root, NewEngine: func() Engine { return &relayEngine{failStart: failStart} }}
	done := make(chan struct{})
	go func() { _ = server.Serve(listener); close(done) }()
	t.Cleanup(func() {
		listener.Close()
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			t.Error("helper sessions did not stop")
		}
		os.RemoveAll(root)
	})
	return path
}

func messages(entries []LogEntry) []string {
	out := []string{}
	for _, e := range entries {
		out = append(out, e.Message)
	}
	return out
}

func TestHelperRelaysSessionLogsIncrementally(t *testing.T) {
	c, err := Inspect(fixture(t), "", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	engine := &PrivilegedEngine{socket: relayHelper(t, false), serverUID: uint32(os.Geteuid())}
	if err = engine.Start(c.Config); err != nil {
		t.Fatal(err)
	}
	// connect reply: "starting" plus the Alive() poll made for reply.Started.
	if got := messages(engine.LogsSince(0)); len(got) != 2 || got[0] != "starting" {
		t.Fatalf("after connect: %v", got)
	}
	engine.Alive()
	engine.Alive()
	got := engine.LogsSince(0)
	// Each status reply carries only entries newer than the session cursor: no duplicates.
	if len(got) != 4 || got[3].Seq != 4 {
		t.Fatalf("after polls: %v", messages(got))
	}
	if err = engine.StopChecked(); err != nil {
		t.Fatal(err)
	}
	if len(engine.LogsSince(0)) != 4 {
		t.Fatal("logs lost after disconnect")
	}
}

func TestHelperRelaysLogsOfRejectedStart(t *testing.T) {
	c, err := Inspect(fixture(t), "", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	engine := &PrivilegedEngine{socket: relayHelper(t, true), serverUID: uint32(os.Geteuid())}
	code(t, engine.Start(c.Config), "start_failed")
	got := engine.LogsSince(0)
	if len(got) != 2 || got[1].Level != "error" {
		t.Fatalf("failed start logs: %v", messages(got))
	}
	if v, _ := field(got[1], "error"); v != "operation not permitted" {
		t.Fatalf("error field = %q", v)
	}
}
