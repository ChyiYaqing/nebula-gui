package client

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func retentionFixture(t *testing.T, versions int) (*Store, []Profile, string) {
	t.Helper()
	source := fixture(t)
	candidate, err := Inspect(source, "Retention", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	store := openStore(t)
	var profiles []Profile
	id := ""
	for i := 0; i < versions; i++ {
		profile, err := store.Save(candidate, id)
		if err != nil {
			t.Fatal(err)
		}
		profiles = append(profiles, profile)
		id = profile.ID
	}
	return store, profiles, source
}
func versionPath(store *Store, p Profile) string {
	return filepath.Join(store.root, "profiles", p.ID, p.Version)
}
func requireVersionCount(t *testing.T, store *Store, id string, count int) {
	t.Helper()
	entries, err := os.ReadDir(filepath.Join(store.root, "profiles", id))
	if err != nil || len(entries) != count {
		t.Fatalf("version count: %d, want %d, error %v", len(entries), count, err)
	}
}
func TestRetentionPreservesCurrentPreviousAndSourceAcrossReopen(t *testing.T) {
	store, profiles, source := retentionFixture(t, 5)
	before, _ := os.ReadFile(source)
	current := profiles[4]
	_, configBefore, _ := store.Load(current.ID)
	if err := store.Prune(""); err != nil {
		t.Fatal(err)
	}
	requireVersionCount(t, store, current.ID, 2)
	rolled, err := store.Rollback(current.ID)
	if err != nil || rolled.Version != profiles[3].Version {
		t.Fatal("rollback lost", err)
	}
	if _, err = store.Rollback(current.ID); err != nil {
		t.Fatal(err)
	}
	root := store.root
	store.Close()
	reopened, err := NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if err := reopened.Prune(""); err != nil {
		t.Fatal(err)
	}
	_, after, err := reopened.Load(current.ID)
	if err != nil || !bytes.Equal(configBefore, after) {
		t.Fatal("current credentials changed", err)
	}
	sourceAfter, _ := os.ReadFile(source)
	if !bytes.Equal(before, sourceAfter) {
		t.Fatal("source changed")
	}
}
func TestRetentionSkipsActiveProfileUntilConfirmedDisconnect(t *testing.T) {
	store, profiles, _ := retentionFixture(t, 4)
	engine := &fakeEngine{alive: true}
	service := NewService(store, engine)
	service.active = profiles[3].ID
	defer service.Close()
	if r := request(service, "list", ""); r.Error != nil {
		t.Fatal(r.Error)
	}
	requireVersionCount(t, store, service.active, 4)
	if r := request(service, "remove", service.active); r.Error == nil || r.Error.Code != "active_profile" {
		t.Fatal("active removal accepted")
	}
	if r := request(service, "disconnect", ""); r.Error != nil {
		t.Fatal(r.Error)
	}
	requireVersionCount(t, store, profiles[3].ID, 2)
}
func TestRetentionCorruptIndexRetainsAllVersions(t *testing.T) {
	store, profiles, _ := retentionFixture(t, 3)
	id := profiles[2].ID
	if err := atomicJSON(filepath.Join(store.root, "profiles", id+".json"), pointer{Version: newID()}); err != nil {
		t.Fatal(err)
	}
	if err := store.Prune(""); err == nil {
		t.Fatal("corrupt index accepted")
	}
	requireVersionCount(t, store, id, 3)
}
func TestRetentionRefusesUnsafeHistoryWithoutFollowingIt(t *testing.T) {
	for _, kind := range []string{"directory_link", "file_link", "hardlink", "nested", "unknown"} {
		t.Run(kind, func(t *testing.T) {
			store, profiles, _ := retentionFixture(t, 3)
			path := versionPath(store, profiles[0])
			outside := t.TempDir()
			sentinel := filepath.Join(outside, "config.yaml")
			if err := os.WriteFile(sentinel, []byte("private sentinel"), 0600); err != nil {
				t.Fatal(err)
			}
			switch kind {
			case "directory_link":
				if err := os.RemoveAll(path); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(outside, path); err != nil {
					t.Fatal(err)
				}
			case "file_link", "hardlink":
				if err := os.Remove(filepath.Join(path, "config.yaml")); err != nil {
					t.Fatal(err)
				}
				var err error
				if kind == "file_link" {
					err = os.Symlink(sentinel, filepath.Join(path, "config.yaml"))
				} else {
					err = os.Link(sentinel, filepath.Join(path, "config.yaml"))
				}
				if err != nil {
					t.Fatal(err)
				}
			case "nested":
				if err := os.Mkdir(filepath.Join(path, "nested"), 0700); err != nil {
					t.Fatal(err)
				}
			case "unknown":
				if err := os.WriteFile(filepath.Join(path, "unknown"), []byte("keep"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			if err := store.Prune(""); err == nil {
				t.Fatal("unsafe history accepted")
			}
			value, _ := os.ReadFile(sentinel)
			if string(value) != "private sentinel" {
				t.Fatal("outside file modified")
			}
			if _, _, err := store.Load(profiles[2].ID); err != nil {
				t.Fatal("current lost", err)
			}
		})
	}
}
func TestRemovalTombstoneRetriesAfterPartialCleanupAndReopen(t *testing.T) {
	store, profiles, source := retentionFixture(t, 3)
	id := profiles[2].ID
	if err := os.Rename(filepath.Join(store.root, "profiles", id+".json"), filepath.Join(store.root, "profiles", id+".removed")); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(versionPath(store, profiles[0]), "config.yaml")); err != nil {
		t.Fatal(err)
	}
	root := store.root
	store.Close()
	reopened, err := NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	if err = reopened.Prune(""); err != nil {
		t.Fatal(err)
	}
	if _, err = os.Lstat(filepath.Join(root, "profiles", id)); !os.IsNotExist(err) {
		t.Fatal("removed profile remained", err)
	}
	if _, err = os.Lstat(filepath.Join(root, "profiles", id+".removed")); !os.IsNotExist(err) {
		t.Fatal("marker remained", err)
	}
	if _, err = os.ReadFile(source); err != nil {
		t.Fatal("source deleted", err)
	}
	if err = reopened.Prune(""); err != nil {
		t.Fatal("retry not idempotent", err)
	}
}
func TestRetentionFailureRetainsCurrentAndRetries(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission denial requires ordinary UID")
	}
	store, profiles, _ := retentionFixture(t, 3)
	old := versionPath(store, profiles[0])
	if err := os.Chmod(old, 0500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(old, 0700)
	service := NewService(store, &fakeEngine{})
	if r := request(service, "list", ""); r.Error != nil {
		t.Fatal(r.Error)
	}
	if len(service.events) != 1 || service.events[0].Code != "profile_cleanup_pending" {
		t.Fatal("no cleanup diagnostic")
	}
	if _, _, err := store.Load(profiles[2].ID); err != nil {
		t.Fatal("current lost", err)
	}
	if err := os.Chmod(old, 0700); err != nil {
		t.Fatal(err)
	}
	if err := store.Prune(""); err != nil {
		t.Fatal(err)
	}
	requireVersionCount(t, store, profiles[2].ID, 2)
}
func TestRetentionLeavesUnindexedProfileForRecovery(t *testing.T) {
	store, profiles, _ := retentionFixture(t, 1)
	if err := os.Remove(filepath.Join(store.root, "profiles", profiles[0].ID+".json")); err != nil {
		t.Fatal(err)
	}
	if err := store.Prune(""); err != nil {
		t.Fatal(err)
	}
	requireVersionCount(t, store, profiles[0].ID, 1)
}

func TestRetentionCleanupUncertaintyKeepsEntireProfile(t *testing.T) {
	store, profiles, _ := retentionFixture(t, 4)
	engine := &uncertainEngine{uncertain: true}
	service := NewService(store, engine)
	service.active = profiles[3].ID
	if r := request(service, "disconnect", ""); r.Error == nil || r.Error.Code != "cleanup_incomplete" {
		t.Fatal("missing cleanup uncertainty")
	}
	if r := request(service, "list", ""); r.Error != nil {
		t.Fatal(r.Error)
	}
	requireVersionCount(t, store, profiles[3].ID, 4)
	engine.uncertain = false
	if r := request(service, "disconnect", ""); r.Error != nil {
		t.Fatal(r.Error)
	}
	requireVersionCount(t, store, profiles[3].ID, 2)
}
func TestRetentionImportCommitSurvivesCleanupFailure(t *testing.T) {
	store, profiles, source := retentionFixture(t, 3)
	if err := os.WriteFile(filepath.Join(versionPath(store, profiles[0]), "unknown"), []byte("preserve"), 0600); err != nil {
		t.Fatal(err)
	}
	candidate, err := Inspect(source, "Updated", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	service := NewService(store, &fakeEngine{})
	response := service.Handle(Request{Version: 1, ID: "import", Method: "import", ProfileID: profiles[2].ID, Path: source, Name: "Updated", Digest: candidate.Profile.Digest})
	if response.Error != nil {
		t.Fatal("committed import reported failure", response.Error)
	}
	saved, ok := response.Result.(Profile)
	if !ok || saved.Version == profiles[2].Version {
		t.Fatal("new version not returned")
	}
	current, _, err := store.Load(saved.ID)
	if err != nil || current.Version != saved.Version {
		t.Fatal("new current lost", err)
	}
	if _, err := store.Rollback(saved.ID); err != nil {
		t.Fatal("rollback lost", err)
	}
	found := false
	for _, event := range service.events {
		if event.Code == "profile_cleanup_pending" {
			found = true
		}
	}
	if !found {
		t.Fatal("no cleanup diagnostic")
	}
}
func TestRemovalFailureIsUnpublishedAndRetriedOnList(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission denial requires ordinary UID")
	}
	store, profiles, _ := retentionFixture(t, 1)
	dir := versionPath(store, profiles[0])
	if err := os.Chmod(dir, 0500); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0700)
	service := NewService(store, &fakeEngine{})
	response := request(service, "remove", profiles[0].ID)
	if response.Error == nil || response.Error.Code != "profile_cleanup_pending" {
		t.Fatal("missing committed-removal result")
	}
	listed, err := store.List()
	if err != nil || len(listed) != 0 {
		t.Fatal("removed profile stayed listed", err)
	}
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if response := request(service, "list", ""); response.Error != nil {
		t.Fatal(response.Error)
	}
	if _, err := os.Lstat(filepath.Join(store.root, "profiles", profiles[0].ID)); !os.IsNotExist(err) {
		t.Fatal("removal did not retry", err)
	}
}
