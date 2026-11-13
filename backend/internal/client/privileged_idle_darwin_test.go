package client

import (
	"bufio"
	"net"
	"os"
	"testing"
	"time"
)

func shortHelperIdleTimeout(t *testing.T) {
	t.Helper()
	previous := helperIdleTimeout
	helperIdleTimeout = 100 * time.Millisecond
	t.Cleanup(func() { helperIdleTimeout = previous })
}

// A quiet controller keeps its tunnel: only disconnect or EOF ends the session (#108).
func TestHelperKeepsTunnelOfIdleController(t *testing.T) {
	shortHelperIdleTimeout(t)
	path, created := testHelper(t, uint32(os.Geteuid()))
	c, err := Inspect(fixture(t), "", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	engine := &PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}
	if err = engine.Start(c.Config); err != nil {
		t.Fatal(err)
	}
	worker := <-created
	select {
	case <-worker.stopped:
		t.Fatal("idle controller lost its tunnel")
	case <-time.After(5 * helperIdleTimeout):
	}
	if !engine.Alive() {
		t.Fatal("session no longer answers after being idle")
	}
	if err = engine.StopChecked(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-worker.stopped:
	case <-time.After(2 * time.Second):
		t.Fatal("disconnect did not stop the tunnel")
	}
}

// A connection that never took the tunnel is still closed when idle.
func TestHelperClosesIdleSessionWithoutTunnel(t *testing.T) {
	shortHelperIdleTimeout(t)
	path, _ := testHelper(t, uint32(os.Geteuid()))
	conn, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err = bufio.NewReader(conn).ReadByte(); err == nil {
		t.Fatal("idle session received data")
	} else if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		t.Fatal("idle session without a tunnel was not closed")
	}
}
