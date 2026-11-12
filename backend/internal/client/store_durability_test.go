package client

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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

func TestStoreSaveIndexSyncFailurePreservesPublishedVersion(t *testing.T) {
	for _, replace := range []bool{false, true} {
		name := "new"
		if replace {
			name = "replace"
		}
		t.Run(name, func(t *testing.T) {
			store := openStore(t)
			var old Profile
			if replace {
				c, err := Inspect(fixture(t), "Old", nil, time.Now())
				if err != nil {
					t.Fatal(err)
				}
				old, err = store.Save(c, "")
				if err != nil {
					t.Fatal(err)
				}
			}
			candidate, err := Inspect(fixture(t), "New", nil, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			injected := errors.New("injected index directory sync failure")
			original := syncDir
			t.Cleanup(func() { syncDir = original })
			failed := false
			syncDir = func(dir string) error {
				if dir == filepath.Join(store.root, "profiles") {
					failed = true
					return injected
				}
				return original(dir)
			}
			if _, err = store.Save(candidate, old.ID); !errors.Is(err, injected) || !failed {
				t.Fatalf("Save error = %v, injected = %v", err, failed)
			}
			entries, err := os.ReadDir(filepath.Join(store.root, "profiles"))
			if err != nil {
				t.Fatal(err)
			}
			var id string
			for _, entry := range entries {
				if strings.HasSuffix(entry.Name(), ".json") {
					id = strings.TrimSuffix(entry.Name(), ".json")
				}
			}
			loaded, config, err := store.Load(id)
			if err != nil {
				t.Fatal(err)
			}
			if loaded.Version == old.Version || loaded.Digest != candidate.Profile.Digest || !bytes.Equal(config, candidate.Config) {
				t.Fatal("Load did not return the new version")
			}
			if replace && loaded.ID != old.ID {
				t.Fatal("replacement changed profile ID")
			}
			profiles, err := store.List()
			if err != nil || len(profiles) != 1 || profiles[0].Version != loaded.Version {
				t.Fatalf("List did not return the published version: count = %d, error = %v", len(profiles), err)
			}
		})
	}
}

func TestStoreSaveBeforePublishSyncFailureCleansVersion(t *testing.T) {
	store := openStore(t)
	candidate, err := Inspect(fixture(t), "Old", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	old, err := store.Save(candidate, "")
	if err != nil {
		t.Fatal(err)
	}
	updated, err := Inspect(fixture(t), "New", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	base := filepath.Join(store.root, "profiles", old.ID)
	injected := errors.New("injected version directory sync failure")
	original := syncDir
	t.Cleanup(func() { syncDir = original })
	var failedVersion string
	syncDir = func(dir string) error {
		if dir == base {
			entries, err := os.ReadDir(base)
			if err != nil {
				t.Fatal(err)
			}
			for _, entry := range entries {
				if entry.IsDir() && entry.Name() != old.Version {
					failedVersion = entry.Name()
				}
			}
			return injected
		}
		return original(dir)
	}
	if _, err = store.Save(updated, old.ID); !errors.Is(err, injected) || failedVersion == "" {
		t.Fatalf("Save error = %v, new version observed = %v", err, failedVersion != "")
	}
	if _, err = os.Stat(filepath.Join(base, failedVersion)); !os.IsNotExist(err) {
		t.Fatalf("unpublished version was not cleaned up: %v", err)
	}
	loaded, config, err := store.Load(old.ID)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Version != old.Version || !bytes.Equal(config, candidate.Config) {
		t.Fatal("old version changed after unpublished Save failure")
	}
}
