package client

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestActiveRenamePreservesConnectionCredentialsAndVersion(t *testing.T) {
	source := fixture(t)
	original, _ := os.ReadFile(source)
	candidate, err := Inspect(source, "Original", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	store := openStore(t)
	profile, err := store.Save(candidate, "")
	if err != nil {
		t.Fatal(err)
	}
	_, configBefore, _ := store.Load(profile.ID)
	engine := &fakeEngine{}
	service := NewService(store, engine)
	defer service.Close()
	if response := request(service, "connect", profile.ID); response.Error != nil {
		t.Fatal(response.Error)
	}
	decoded, err := DecodeRequest([]byte(`{"version":1,"id":"rename","method":"rename","profileID":"` + profile.ID + `","name":"  工作网络  "}`))
	if err != nil {
		t.Fatal(err)
	}
	response := service.Handle(decoded)
	if response.Error != nil {
		t.Fatal(response.Error)
	}
	renamed, configAfter, err := store.Load(profile.ID)
	if err != nil {
		t.Fatal(err)
	}
	if renamed.Name != "工作网络" || renamed.Version != profile.Version || renamed.Digest != profile.Digest || renamed.Fingerprint != profile.Fingerprint || !renamed.ImportedAt.Equal(profile.ImportedAt) {
		t.Fatal("rename changed identity or config version")
	}
	if !bytes.Equal(configBefore, configAfter) {
		t.Fatal("rename rewrote credentials/config")
	}
	after, _ := os.ReadFile(source)
	if !bytes.Equal(original, after) {
		t.Fatal("rename modified original source")
	}
	if !engine.alive || engine.starts != 1 || engine.stops != 0 {
		t.Fatal("rename disturbed connection")
	}
	index, _ := store.index(profile.ID)
	if index.DisplayName != "工作网络" || index.Previous != "" {
		t.Fatal("rename consumed rollback version")
	}
	info, _ := os.Stat(filepath.Join(store.root, "profiles", profile.ID+".json"))
	if info.Mode().Perm() != 0600 {
		t.Fatal("rename exposed metadata permissions")
	}
}
func TestRenameLegacyIndexPersistsThroughUpdateRollbackAndReopen(t *testing.T) {
	source := fixture(t)
	candidate, err := Inspect(source, "Original", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	store := openStore(t)
	first, err := store.Save(candidate, "")
	if err != nil {
		t.Fatal(err)
	}
	indexPath := filepath.Join(store.root, "profiles", first.ID+".json")
	if err = atomicJSON(indexPath, pointer{Version: first.Version}); err != nil {
		t.Fatal(err)
	} // v0.3 format.
	if loaded, _, err := store.Load(first.ID); err != nil || loaded.Name != "Original" {
		t.Fatal("legacy index not readable", err)
	}
	if _, err = store.Rename(first.ID, "Friendly"); err != nil {
		t.Fatal(err)
	}
	service := NewService(store, &fakeEngine{})
	defer service.Close()
	response := service.Handle(Request{Version: 1, ID: "update", Method: "import", Path: source, ProfileID: first.ID, Digest: candidate.Profile.Digest})
	if response.Error != nil {
		t.Fatal(response.Error)
	}
	updated, _, err := store.Load(first.ID)
	if err != nil || updated.Name != "Friendly" || updated.Version == first.Version {
		t.Fatal("default update lost display name", err)
	}
	restored, err := store.Rollback(first.ID)
	if err != nil || restored.Version != first.Version || restored.Name != "Friendly" {
		t.Fatal("rollback lost display name", err)
	}
	if _, err = store.Rename(first.ID, " Friendly "); err != nil {
		t.Fatal(err)
	}
	root := store.root
	store.Close()
	reopened, err := NewStore(root)
	if err != nil {
		t.Fatal(err)
	}
	defer reopened.Close()
	loaded, _, err := reopened.Load(first.ID)
	if err != nil || loaded.Name != "Friendly" {
		t.Fatal("display name did not persist", err)
	}
}
func TestRenameRejectsInvalidNamesWithoutMutation(t *testing.T) {
	store := openStore(t)
	candidate, err := Inspect(fixture(t), "Original", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	profile, err := store.Save(candidate, "")
	if err != nil {
		t.Fatal(err)
	}
	indexPath := filepath.Join(store.root, "profiles", profile.ID+".json")
	before, _ := os.ReadFile(indexPath)
	for _, name := range []string{"", "   ", "one\ntwo", "one\ttwo", "a\x00b", strings.Repeat("中", 54), string([]byte{0xff})} {
		_, err := store.Rename(profile.ID, name)
		code(t, err, "invalid_name")
		after, _ := os.ReadFile(indexPath)
		if !bytes.Equal(before, after) {
			t.Fatal("invalid rename mutated index")
		}
	}
	valid := strings.Repeat("中", 53) + "a"
	if _, err = store.Rename(profile.ID, valid); err != nil {
		t.Fatal("valid UTF-8 boundary rejected", err)
	}
	_, err = store.Rename("../escape", "Valid")
	code(t, err, "invalid_id")
}
