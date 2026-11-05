package client

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

// The runtime parent may be writable by group daemon, so root must never follow
// a link planted at the socket path when handing the socket to its controller.
func TestSecureSocketDoesNotFollowLinks(t *testing.T) {
	dir, err := os.MkdirTemp("", "nsock") // Short path: unix socket names are limited to 104 bytes.
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	uid := uint32(os.Geteuid())
	target := filepath.Join(dir, "target")
	if err = os.WriteFile(target, nil, 0644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "link.sock")
	if err = os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if secureSocket(link, uid) == nil {
		t.Fatal("accepted a symbolic link as the control socket")
	}
	if st, err := os.Stat(target); err != nil || st.Mode().Perm() != 0644 {
		t.Fatalf("followed the link and changed its target: %v %v", st.Mode(), err)
	}
	path := filepath.Join(dir, "helper.sock")
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	if err = os.Chmod(path, 0666); err != nil {
		t.Fatal(err)
	}
	if err = secureSocket(path, uid); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Lstat(path); err != nil || st.Mode()&os.ModeSocket == 0 || st.Mode().Perm() != 0600 {
		t.Fatalf("socket not restricted: %v %v", st.Mode(), err)
	}
}
