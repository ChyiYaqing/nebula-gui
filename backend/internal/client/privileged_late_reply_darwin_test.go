package client

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func lateReplyPair(t *testing.T) (*PrivilegedEngine, *net.UnixConn) {
	t.Helper()
	fds, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	var conns [2]*net.UnixConn
	for i, fd := range fds {
		file := os.NewFile(uintptr(fd), "helper-test")
		conn, err := net.FileConn(file)
		file.Close()
		if err != nil {
			t.Fatal(err)
		}
		conns[i] = conn.(*net.UnixConn)
		t.Cleanup(func() { conn.Close() })
	}
	return &PrivilegedEngine{conn: conns[0], reader: bufio.NewReader(conns[0])}, conns[1]
}

func lateReplyHelper(t *testing.T, run func() error) {
	t.Helper()
	done := make(chan error, 1)
	go func() { done <- run() }()
	t.Cleanup(func() {
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("fake helper: %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Error("fake helper did not finish")
		}
	})
}

func requireHelperTimeout(t *testing.T, err error) {
	t.Helper()
	var timeout net.Error
	if !errors.As(err, &timeout) || !timeout.Timeout() {
		t.Fatalf("expected timeout, got %v", err)
	}
}

func shortHelperTimeout(t *testing.T) {
	t.Helper()
	previous := helperExchangeTimeout
	helperExchangeTimeout = 100 * time.Millisecond
	t.Cleanup(func() { helperExchangeTimeout = previous })
}

func TestPrivilegedLateReplyPreservesLogs(t *testing.T) {
	engine, server := lateReplyPair(t)
	lateReplyHelper(t, func() error {
		decoder, encoder := json.NewDecoder(server), json.NewEncoder(server)
		var first, second helperRequest
		if err := decoder.Decode(&first); err != nil {
			return err
		}
		// Expire the first read after its request was sent. No source hook or 10 s wait.
		if err := engine.conn.SetReadDeadline(time.Now()); err != nil {
			return err
		}
		if err := decoder.Decode(&second); err != nil {
			return err
		}
		if first.ID == second.ID {
			return errors.New("request ID did not advance")
		}
		if err := encoder.Encode(helperReply{Version: 1, ID: first.ID, Revision: KernelRevision, Logs: []LogEntry{{Message: "late log"}}}); err != nil {
			return err
		}
		return encoder.Encode(helperReply{Version: 1, ID: second.ID, Revision: KernelRevision, Started: true, Logs: []LogEntry{{Message: "current log"}}})
	})
	_, err := engine.exchange("status", "")
	requireHelperTimeout(t, err)
	reply, err := engine.exchange("status", "")
	if err != nil || !reply.Started || reply.ID != stringID(2) {
		t.Fatalf("second exchange: reply=%+v, err=%v", reply, err)
	}
	logs := engine.LogsSince(0)
	if len(logs) != 2 || logs[0].Message != "late log" || logs[1].Message != "current log" {
		t.Fatalf("relayed logs: %+v", logs)
	}
}

func TestPrivilegedLateReplyRejectsInvalidFrames(t *testing.T) {
	for _, name := range []string{"forged", "future", "zero", "version", "revision", "malformed"} {
		t.Run(name, func(t *testing.T) {
			engine, server := lateReplyPair(t)
			lateReplyHelper(t, func() error {
				decoder := json.NewDecoder(server)
				var first, second helperRequest
				if err := decoder.Decode(&first); err != nil {
					return err
				}
				if err := engine.conn.SetReadDeadline(time.Now()); err != nil {
					return err
				}
				if err := decoder.Decode(&second); err != nil {
					return err
				}
				reply := helperReply{Version: 1, ID: first.ID, Revision: KernelRevision, Logs: []LogEntry{{Message: "invalid log"}}}
				switch name {
				case "forged":
					reply.ID = "never-sent"
				case "future":
					reply.ID = stringID(3)
				case "zero":
					reply.ID = stringID(0)
				case "version":
					reply.Version = 2
				case "revision":
					reply.Revision = "wrong-revision"
				case "malformed":
					_, err := server.Write([]byte("not-json\n"))
					return err
				}
				return json.NewEncoder(server).Encode(reply)
			})
			_, err := engine.exchange("status", "")
			requireHelperTimeout(t, err)
			_, err = engine.exchange("status", "")
			code(t, err, "helper_mismatch")
			if logs := engine.LogsSince(0); len(logs) != 0 {
				t.Fatalf("invalid reply relayed logs: %+v", logs)
			}
		})
	}
}

func TestPrivilegedLateRepliesDoNotExtendDeadline(t *testing.T) {
	shortHelperTimeout(t)
	engine, server := lateReplyPair(t)
	const unanswered = 3
	lateReplyHelper(t, func() error {
		decoder, encoder := json.NewDecoder(server), json.NewEncoder(server)
		var late [unanswered]helperRequest
		for i := range late {
			if err := decoder.Decode(&late[i]); err != nil {
				return err
			}
		}
		var current helperRequest
		if err := decoder.Decode(&current); err != nil {
			return err
		}
		// Late replies keep arriving, but the current request is never answered.
		for _, request := range late {
			time.Sleep(20 * time.Millisecond)
			if err := encoder.Encode(helperReply{Version: 1, ID: request.ID, Revision: KernelRevision, Logs: []LogEntry{{Message: "late log"}}}); err != nil {
				return err
			}
		}
		return nil
	})
	for i := 0; i < unanswered; i++ {
		_, err := engine.exchange("status", "")
		requireHelperTimeout(t, err)
	}
	// Bound even a regression that keeps renewing the deadline for every late reply.
	watchdog := time.AfterFunc(time.Second, func() { engine.conn.Close() })
	defer watchdog.Stop()
	start := time.Now()
	reply, err := engine.exchange("status", "")
	requireHelperTimeout(t, err)
	if elapsed := time.Since(start); elapsed < 80*time.Millisecond || elapsed >= time.Second {
		t.Fatalf("deadline changed: elapsed=%v", elapsed)
	}
	if reply.ID != "" {
		t.Fatalf("timeout returned a discarded reply: %+v", reply)
	}
	if logs := engine.LogsSince(0); len(logs) != unanswered {
		t.Fatalf("late replies were not read and preserved: %+v", logs)
	}
	if len(engine.sentIDs) != 1 {
		t.Fatalf("only the unanswered request should stay recorded: %v", engine.sentIDs)
	}
}

// An ID is accepted once: a second copy of an already consumed reply is a protocol error.
func TestPrivilegedLateReplyIsAcceptedOnlyOnce(t *testing.T) {
	shortHelperTimeout(t)
	engine, server := lateReplyPair(t)
	lateReplyHelper(t, func() error {
		decoder, encoder := json.NewDecoder(server), json.NewEncoder(server)
		var first, second helperRequest
		if err := decoder.Decode(&first); err != nil {
			return err
		}
		if err := decoder.Decode(&second); err != nil {
			return err
		}
		late := helperReply{Version: 1, ID: first.ID, Revision: KernelRevision}
		if err := encoder.Encode(late); err != nil {
			return err
		}
		return encoder.Encode(late)
	})
	_, err := engine.exchange("status", "")
	requireHelperTimeout(t, err)
	_, err = engine.exchange("status", "")
	var p *Problem
	if !errors.As(err, &p) || p.Code != "helper_mismatch" {
		t.Fatalf("expected helper_mismatch, got %v", err)
	}
}

func TestPrivilegedStartDoesNotAcceptPreviousSessionID(t *testing.T) {
	root, err := os.MkdirTemp("/private/tmp", "ng-late-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	path := filepath.Join(root, "h.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	lateReplyHelper(t, func() error {
		var oldID string
		for session := 0; session < 2; session++ {
			conn, err := listener.AcceptUnix()
			if err != nil {
				return err
			}
			defer conn.Close()
			decoder, encoder := json.NewDecoder(conn), json.NewEncoder(conn)
			for _, method := range []string{"connect", "disconnect"} {
				var request helperRequest
				if err := decoder.Decode(&request); err != nil {
					return err
				}
				if session == 0 && method == "connect" {
					oldID = request.ID
				}
				reply := helperReply{Version: 1, ID: request.ID, Revision: KernelRevision, Started: method == "connect"}
				if session == 1 && method == "disconnect" {
					if request.ID != stringID(4) {
						return errors.New("request IDs did not advance across Start")
					}
					if err := encoder.Encode(helperReply{Version: 1, ID: oldID, Revision: KernelRevision, Logs: []LogEntry{{Message: "old session log"}}}); err != nil {
						return err
					}
				}
				if err := encoder.Encode(reply); err != nil {
					return err
				}
			}
		}
		return nil
	})
	engine := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	t.Cleanup(func() {
		if engine.conn != nil {
			engine.conn.Close()
		}
	})
	for session := 0; session < 2; session++ {
		if err := engine.Start([]byte("fake config")); err != nil {
			t.Fatal(err)
		}
		if session == 0 {
			if err := engine.StopChecked(); err != nil {
				t.Fatal(err)
			}
		} else {
			_, err := engine.exchange("disconnect", "")
			code(t, err, "helper_mismatch")
		}
	}
	if logs := engine.LogsSince(0); len(logs) != 0 {
		t.Fatalf("previous session's logs accepted: %+v", logs)
	}
}

func TestPrivilegedPartialFrameTimeoutStillCannotResynchronize(t *testing.T) {
	shortHelperTimeout(t)
	engine, server := lateReplyPair(t)
	lateReplyHelper(t, func() error {
		decoder := json.NewDecoder(server)
		var first, second helperRequest
		if err := decoder.Decode(&first); err != nil {
			return err
		}
		frame, err := json.Marshal(helperReply{Version: 1, ID: first.ID, Revision: KernelRevision})
		if err != nil {
			return err
		}
		cut := len(frame) / 2
		if _, err := server.Write(frame[:cut]); err != nil {
			return err
		}
		if err := decoder.Decode(&second); err != nil {
			return err
		}
		if _, err := server.Write(append(frame[cut:], '\n')); err != nil {
			return err
		}
		return json.NewEncoder(server).Encode(helperReply{Version: 1, ID: second.ID, Revision: KernelRevision})
	})
	_, err := engine.exchange("status", "")
	requireHelperTimeout(t, err)
	_, err = engine.exchange("status", "")
	code(t, err, "helper_mismatch")
}

func TestHelperOneShotReplyStillRequiresExactID(t *testing.T) {
	for _, id := range []string{"health", "recover"} {
		t.Run(id, func(t *testing.T) {
			engine, server := lateReplyPair(t)
			lateReplyHelper(t, func() error {
				var request helperRequest
				if err := json.NewDecoder(server).Decode(&request); err != nil {
					return err
				}
				return json.NewEncoder(server).Encode(helperReply{Version: 1, ID: stringID(1), Revision: KernelRevision})
			})
			_, err := helperExchange(engine.conn, engine.reader, helperRequest{Version: 1, ID: id, Method: "health"}, nil)
			code(t, err, "helper_mismatch")
		})
	}
}
