package main

import (
	"bufio"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"

	"nebula-gui/backend/internal/client"
)

type idleEngine struct{}

func (idleEngine) Start([]byte) error   { return nil }
func (idleEngine) Stop()                {}
func (idleEngine) Alive() bool          { return false }
func (idleEngine) Peers() []client.Peer { return nil }

func newIdleService(store *client.Store) *client.Service { return client.NewService(store, idleEngine{}) }

type session struct {
	t    *testing.T
	in   *io.PipeWriter
	out  *bufio.Reader
	done chan int
}

func start(t *testing.T, root string) *session {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	s := &session{t: t, in: inW, out: bufio.NewReader(outR), done: make(chan int, 1)}
	go func() { s.done <- serve(root, newIdleService, inR, outW); _ = outW.Close() }()
	return s
}

func (s *session) send(id, method string) map[string]any {
	s.t.Helper()
	line, _ := json.Marshal(map[string]any{"version": 1, "id": id, "method": method})
	if _, err := s.in.Write(append(line, '\n')); err != nil {
		s.t.Fatal(err)
	}
	reply, err := s.out.ReadBytes('\n')
	if err != nil {
		s.t.Fatalf("no reply to %s: %v", id, err)
	}
	var response map[string]any
	if err := json.Unmarshal(reply, &response); err != nil || response["id"] != id {
		s.t.Fatalf("reply %q", reply)
	}
	return response
}

func (s *session) finish() int { _ = s.in.Close(); return <-s.done }

func problemCode(response map[string]any) string {
	problem, _ := response["error"].(map[string]any)
	code, _ := problem["code"].(string)
	return code
}

// #84: an unusable store is reported per request instead of exiting, which the GUI
// took for a crashed backend and an unconfirmed tunnel cleanup.
func TestStoreThatIsNotPrivateIsReportedWithoutExiting(t *testing.T) {
	root := filepath.Join(t.TempDir(), "store")
	if err := os.Mkdir(root, 0755); err != nil {
		t.Fatal(err)
	}
	s := start(t, root)
	for _, id := range []string{"a", "b"} {
		if code := problemCode(s.send(id, "list")); code != "store_unavailable" {
			t.Fatalf("%s: code %q", id, code)
		}
	}
	if exit := s.finish(); exit != 0 {
		t.Fatalf("exit %d", exit)
	}
}

func TestStoreInUseRecoversOnceReleased(t *testing.T) {
	root := filepath.Join(t.TempDir(), "store")
	owner, err := client.NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	s := start(t, root)
	if code := problemCode(s.send("a", "list")); code != "store_in_use" {
		t.Fatalf("code %q", code)
	}
	owner.Close()
	response := s.send("b", "list")
	if response["error"] != nil {
		t.Fatalf("after release: %v", response["error"])
	}
	if profiles, ok := response["result"].([]any); !ok || len(profiles) != 0 {
		t.Fatalf("result %v", response["result"])
	}
	if exit := s.finish(); exit != 0 {
		t.Fatalf("exit %d", exit)
	}
	// The recovered backend holds the lock until it exits.
	again, err := client.NewStore(root)
	if err != nil {
		t.Fatalf("lock not released on exit: %v", err)
	}
	again.Close()
}
