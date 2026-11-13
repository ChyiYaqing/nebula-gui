package client

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestReleaseNewer(t *testing.T) {
	for _, tt := range []struct {
		a, b string
		want bool
	}{
		{"0.4.3", "0.4.2", true},
		{"0.10.0", "0.9.9", true},
		{"1.0", "0.9.9", true},
		{"0.4.2.1", "0.4.2", true},
		{"0.4.2", "0.4.2", false},
		{"0.4.2", "0.4.2.0", false},
		{"0.4.1", "0.4.2", false},
		{"0.3.1", "0.4.2", false},
		{"", "0.4.2", false},
		{"0.5.x", "0.4.2", false},
		{"0.5.0-beta", "0.4.2", false},
		{"-1.0", "0.4.2", false},
	} {
		if got := releaseNewer(tt.a, tt.b); got != tt.want {
			t.Errorf("releaseNewer(%q, %q) = %v, want %v", tt.a, tt.b, got, tt.want)
		}
	}
}

// A component from another release answers health; only a later one is reported as newer (#115).
func TestAuthorizationReportsNewerHelper(t *testing.T) {
	for _, tt := range []struct {
		release       string
		update, newer bool
	}{
		{HelperRelease, false, false},
		{"0.3.1", true, false},
		{"99.0.0", true, true},
		{"", true, false},
	} {
		directory, err := os.MkdirTemp("/tmp", "nh")
		if err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(directory)
		if err = os.Chmod(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(directory, "s")
		listener, err := net.Listen("unix", path)
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		go func() {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			defer conn.Close()
			if _, err = bufio.NewReader(conn).ReadBytes('\n'); err != nil {
				return
			}
			_ = json.NewEncoder(conn).Encode(helperReply{Version: 1, ID: "health", Revision: KernelRevision, HelperRelease: tt.release})
		}()
		state := (&PrivilegedEngine{socket: path, serverUID: uint32(os.Geteuid())}).Authorization()
		if !state.Available || state.UpdateRequired != tt.update || state.HelperNewer != tt.newer {
			t.Errorf("release %q: %+v", tt.release, state)
		}
	}
}
