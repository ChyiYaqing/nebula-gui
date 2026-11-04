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

func (e *controlledEngine) Rebind() error { return nil }

func TestRecoveryProofRespectsControllerOwnership(t *testing.T) {
	path, created := testHelper(t, uint32(os.Geteuid()))
	candidate, err := Inspect(fixture(t), "", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	owner := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	challenger := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	state := owner.Authorization()
	if !state.Available || state.UpdateRequired || state.HelperRelease != HelperRelease {
		t.Fatal(state)
	}
	if err = owner.Start(candidate.Config); err != nil {
		t.Fatal(err)
	}
	worker := <-created
	code(t, challenger.RecoverChecked(), "cleanup_pending")
	code(t, challenger.Start(candidate.Config), "cleanup_incomplete")
	if !worker.Alive() {
		t.Fatal("recovery disconnected another controller")
	}
	if err = owner.Rebind(); err != nil {
		t.Fatal(err)
	}
	if err = owner.StopChecked(); err != nil {
		t.Fatal(err)
	}
	if err = challenger.RecoverChecked(); err != nil {
		t.Fatal(err)
	}
	if err = challenger.Start(candidate.Config); err != nil {
		t.Fatal(err)
	}
	<-created
	if err = challenger.StopChecked(); err != nil {
		t.Fatal(err)
	}
}
func TestLegacyComponentRemainsUsableWithoutNewOperations(t *testing.T) {
	root, err := os.MkdirTemp("/private/tmp", "ng-legacy-")
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
	done := make(chan error, 1)
	go func() {
		conn, err := listener.AcceptUnix()
		if err != nil {
			done <- err
			return
		}
		defer conn.Close()
		reader := bufio.NewReader(conn)
		for _, expected := range []string{"connect", "disconnect"} {
			data, err := readHelperFrame(reader)
			if err != nil {
				done <- err
				return
			}
			var request helperRequest
			if err = json.Unmarshal(data, &request); err != nil || request.Method != expected {
				done <- errors.New("new operation sent to legacy controller")
				return
			}
			err = json.NewEncoder(conn).Encode(helperReply{Version: 1, ID: request.ID, Revision: KernelRevision, Started: expected == "connect", Peers: []Peer{}})
			if err != nil {
				done <- err
				return
			}
		}
		done <- nil
	}()
	engine := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	if err = engine.Start([]byte("legacy fixture")); err != nil {
		t.Fatal(err)
	}
	code(t, engine.Rebind(), "helper_upgrade_required")
	if err = engine.StopChecked(); err != nil {
		t.Fatal(err)
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
}

func TestCleanupProofFencesAcceptedButDelayedConnect(t *testing.T) {
	root, err := os.MkdirTemp("/private/tmp", "ng-fence-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(root)
	path := filepath.Join(root, "h.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	reached, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	starts := make(chan struct{}, 4)
	server := &HelperServer{AllowedUID: uint32(os.Geteuid()), TemporaryRoot: root,
		NewEngine:     func() Engine { starts <- struct{}{}; return &controlledEngine{stopped: make(chan struct{})} },
		beforeConnect: func() { once.Do(func() { close(reached); <-release }) },
	}
	done := make(chan struct{})
	go func() { _ = server.Serve(listener); close(done) }()
	defer func() { listener.Close(); <-done }()
	candidate, err := Inspect(fixture(t), "", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	old := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	result := make(chan error, 1)
	go func() { result <- old.Start(candidate.Config) }()
	<-reached
	recovery := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	if err = recovery.RecoverChecked(); err != nil {
		close(release)
		t.Fatal(err)
	}
	close(release)
	code(t, <-result, "cleanup_pending")
	select {
	case <-starts:
		t.Fatal("old request started after cleanup proof")
	default:
	}
	if err = recovery.Start(candidate.Config); err != nil {
		t.Fatal(err)
	}
	<-starts
	if err = recovery.StopChecked(); err != nil {
		t.Fatal(err)
	}
}

func TestRecoveryTransportFailureIsNotMisreportedAsUpgrade(t *testing.T) {
	for _, mode := range []string{"eof", "malformed", "legacy", "pending"} {
		t.Run(mode, func(t *testing.T) {
			root, err := os.MkdirTemp("/private/tmp", "ng-proof-")
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
				conn, err := listener.AcceptUnix()
				if err != nil {
					return
				}
				defer conn.Close()
				_, _ = readHelperFrame(bufio.NewReader(conn))
				switch mode {
				case "eof":
					return
				case "malformed":
					_, _ = conn.Write([]byte("invalid\n"))
				case "legacy":
					_ = json.NewEncoder(conn).Encode(helperReply{Version: 1, ID: "recover", Revision: KernelRevision, Error: &Problem{Code: "invalid_request"}})
				case "pending":
					_ = json.NewEncoder(conn).Encode(helperReply{Version: 1, ID: "recover", Revision: KernelRevision, HelperRelease: HelperRelease, Error: &Problem{Code: "cleanup_pending"}})
				}
			}()
			engine := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
			want := "cleanup_incomplete"
			if mode == "legacy" {
				want = "helper_upgrade_required"
			}
			if mode == "pending" {
				want = "cleanup_pending"
			}
			code(t, engine.RecoverChecked(), want)
			code(t, engine.Start([]byte("must remain blocked")), "cleanup_incomplete")
			<-done
		})
	}
}
