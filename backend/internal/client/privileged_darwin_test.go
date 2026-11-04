package client

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"go.yaml.in/yaml/v3"
)

type controlledEngine struct {
	mu      sync.Mutex
	alive   bool
	stopped chan struct{}
	once    sync.Once
}

func (e *controlledEngine) Start([]byte) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.alive = true
	return nil
}
func (e *controlledEngine) Stop() {
	e.mu.Lock()
	e.alive = false
	e.mu.Unlock()
	e.once.Do(func() { close(e.stopped) })
}
func (e *controlledEngine) Alive() bool   { e.mu.Lock(); defer e.mu.Unlock(); return e.alive }
func (e *controlledEngine) Peers() []Peer { return []Peer{} }
func testHelper(t *testing.T, uid uint32) (string, <-chan *controlledEngine) {
	t.Helper()
	root, err := os.MkdirTemp("/private/tmp", "ng-h-")
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, "h.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	created := make(chan *controlledEngine, 4)
	server := &HelperServer{AllowedUID: uid, TemporaryRoot: root, NewEngine: func() Engine { e := &controlledEngine{stopped: make(chan struct{})}; created <- e; return e }}
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
	return path, created
}
func TestPrivilegedPeerIdentityAndMissingAuthorization(t *testing.T) {
	engine := NewPrivilegedEngine()
	engine.socket = filepath.Join(t.TempDir(), "missing.sock")
	if engine.Authorization().Available {
		t.Fatal("missing helper marked available")
	}
	code(t, engine.Start([]byte("ignored")), "authorization_required")
	path, _ := testHelper(t, uint32(os.Geteuid()))
	engine = &PrivilegedEngine{socket: path, serverUID: 0}
	if engine.Authorization().Available {
		t.Fatal("ordinary-user server accepted as root")
	}
	path, _ = testHelper(t, uint32(os.Geteuid())+1)
	engine = &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	if engine.Authorization().Available {
		t.Fatal("wrong controller UID accepted")
	}
}
func TestPrivilegedSessionConnectDisconnectAndEOF(t *testing.T) {
	for _, drop := range []bool{false, true} {
		t.Run(map[bool]string{false: "disconnect", true: "EOF"}[drop], func(t *testing.T) {
			path, created := testHelper(t, uint32(os.Geteuid()))
			c, err := Inspect(fixture(t), "", nil, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			engine := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
			if !engine.Authorization().Available {
				t.Fatal("health check failed")
			}
			if err = engine.Start(c.Config); err != nil {
				t.Fatal(err)
			}
			worker := <-created
			if !engine.Alive() {
				t.Fatal("session not started")
			}
			if drop {
				engine.conn.Close()
				engine.conn = nil
			} else {
				if err = engine.StopChecked(); err != nil {
					t.Fatal(err)
				}
			}
			select {
			case <-worker.stopped:
			case <-time.After(2 * time.Second):
				t.Fatal("session did not stop its tunnel")
			}
		})
	}
}
func TestPrivilegedHelperRejectsPathsCommandsAndResourceBombs(t *testing.T) {
	for _, body := range []string{`{"version":1,"id":"x","method":"connect","path":"/etc/passwd"}`, `{"version":1,"id":"x","method":"shell","config":""}`, `{"version":2,"id":"x","method":"health"}`, `{"version":1,"id":"x","method":"health","config":"secret"}`} {
		if _, err := decodeHelperRequest([]byte(body)); err == nil {
			t.Fatal("accepted out-of-contract operation")
		}
	}
	_, err := validateInline([]byte("pki:\n  ca: /etc/passwd\n  cert: host.crt\n  key: host.key\n"), t.TempDir())
	code(t, err, "inline_required")
	for _, tc := range []struct {
		scope, key string
		value      any
	}{
		{"handshakes", "trigger_buffer", -1}, {"handshakes", "query_buffer", 4294967295}, {"tun", "routines", 65536}, {"listen", "routines", 65536}, {"listen", "batch", 99999999}, {"tun", "tx_queue", -1},
	} {
		config := map[string]any{tc.scope: map[string]any{tc.key: tc.value}}
		raw, _ := yaml.Marshal(config)
		_, err := validateInline(raw, t.TempDir())
		code(t, err, "unsupported") // This must fail before Inspect/kernel allocations or credential loading.
	}
}
func TestPrivilegedHelperRejectsSecondController(t *testing.T) {
	path, created := testHelper(t, uint32(os.Geteuid()))
	c, err := Inspect(fixture(t), "", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	first := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	second := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	if err = first.Start(c.Config); err != nil {
		t.Fatal(err)
	}
	_ = <-created
	defer first.Stop()
	code(t, second.Start(c.Config), "already_connected")
}
func TestPrivilegedMalformedReplyLocksCleanupWarning(t *testing.T) {
	root, err := os.MkdirTemp("/private/tmp", "ng-p-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	path := filepath.Join(root, "h.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, e := listener.AcceptUnix()
		if e != nil {
			return
		}
		defer conn.Close()
		reader := bufio.NewReader(conn)
		_, _ = readHelperFrame(reader)
		_ = json.NewEncoder(conn).Encode(map[string]any{"version": 99, "id": "wrong", "started": true})
	}()
	engine := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	code(t, engine.Start([]byte("config")), "cleanup_incomplete")
	code(t, engine.Start([]byte("config")), "cleanup_incomplete")
	code(t, engine.StopChecked(), "cleanup_incomplete")
	<-done
}
func TestHelperWorkerRefusesUnprivilegedExecution(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("ordinary-user boundary test")
	}
	if err := ServePrivilegedHelper(uint32(os.Geteuid())); err == nil || errors.Is(err, net.ErrClosed) {
		t.Fatal("root helper guard did not reject ordinary execution")
	}
}
