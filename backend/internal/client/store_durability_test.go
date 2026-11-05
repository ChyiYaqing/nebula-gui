package client

import (
	"os"
	"path/filepath"
	"testing"
)

// Managed config files are created fresh: a planted link or existing file is never written through.
func TestManagedConfigWriteNeverFollowsOrReplaces(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "elsewhere")
	if err := os.WriteFile(target, []byte("original"), 0644); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "config.yaml")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if writeSynced(link, []byte("managed")) == nil {
		t.Fatal("wrote through a symbolic link")
	}
	if b, _ := os.ReadFile(target); string(b) != "original" {
		t.Fatalf("link target changed: %q", b)
	}
	fresh := filepath.Join(dir, "fresh.yaml")
	if err := writeSynced(fresh, []byte("managed")); err != nil {
		t.Fatal(err)
	}
	if st, err := os.Stat(fresh); err != nil || st.Mode().Perm() != 0600 {
		t.Fatalf("unexpected mode: %v %v", st.Mode(), err)
	}
	if writeSynced(fresh, []byte("again")) == nil {
		t.Fatal("replaced an existing managed file")
	}
}
