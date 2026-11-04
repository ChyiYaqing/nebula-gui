package client

import (
	"testing"
	"time"
)

type uncertainEngine struct {
	fakeEngine
	uncertain bool
}

func (e *uncertainEngine) StopChecked() error {
	if e.uncertain {
		return problem("cleanup_incomplete", "test cleanup uncertainty", "")
	}
	e.Stop()
	return nil
}
func TestCleanupUncertaintyKeepsProfileProtected(t *testing.T) {
	store := openStore(t)
	c, err := Inspect(fixture(t), "", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	profile, err := store.Save(c, "")
	if err != nil {
		t.Fatal(err)
	}
	engine := &uncertainEngine{}
	service := NewService(store, engine)
	defer service.Close()
	if r := request(service, "connect", profile.ID); r.Error != nil {
		t.Fatal(r.Error)
	}
	engine.alive = false
	engine.uncertain = true
	state := service.status()
	if state.State != "failed" || state.ProfileID != profile.ID || state.Error.Code != "cleanup_incomplete" {
		t.Fatal("cleanup uncertainty lost its identity or error")
	}
	if r := request(service, "remove", profile.ID); r.Error == nil || r.Error.Code != "active_profile" {
		t.Fatal("uncertain profile was removable")
	}
	if r := request(service, "connect", profile.ID); r.Error == nil || r.Error.Code != "cleanup_incomplete" {
		t.Fatal("uncertain connection was treated as successful")
	}
	if engine.starts != 1 {
		t.Fatal("unexpected retry before cleanup confirmation")
	}
	if r := request(service, "disconnect", ""); r.Error == nil || r.Error.Code != "cleanup_incomplete" {
		t.Fatal("failed disconnect reported success")
	}
	engine.uncertain = false
	if r := request(service, "disconnect", ""); r.Error != nil {
		t.Fatal(r.Error)
	}
	if service.status().ProfileID != "" {
		t.Fatal("confirmed cleanup retained the active identity")
	}
}
func TestConnectionTimingAndEventWindow(t *testing.T) {
	store := openStore(t)
	c, err := Inspect(fixture(t), "", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	profile, err := store.Save(c, "")
	if err != nil {
		t.Fatal(err)
	}
	service := NewService(store, &fakeEngine{})
	defer service.Close()
	if service.status().StartedAt != nil {
		t.Fatal("disconnected session has a start time")
	}
	if r := request(service, "connect", profile.ID); r.Error != nil {
		t.Fatal(r.Error)
	}
	started := service.status().StartedAt
	if started == nil || service.status().ObservedAt.Before(*started) {
		t.Fatal("missing connection timing")
	}
	for i := 0; i < 110; i++ {
		service.event("test_event")
	}
	r := request(service, "events", "")
	events, ok := r.Result.([]Event)
	if !ok || len(events) != 100 {
		t.Fatal("event window not bounded")
	}
	events[0].Code = "changed"
	if service.events[0].Code == "changed" {
		t.Fatal("event snapshot leaked mutable storage")
	}
	if r := request(service, "disconnect", ""); r.Error != nil {
		t.Fatal(r.Error)
	}
	if service.status().StartedAt != nil {
		t.Fatal("disconnect retained the start time")
	}
}

func TestUncertainInitialStartProtectsAttemptedProfile(t *testing.T) {
	path := fixture(t)
	store := openStore(t)
	c, err := Inspect(path, "", nil, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	profile, err := store.Save(c, "")
	if err != nil {
		t.Fatal(err)
	}
	engine := &uncertainEngine{fakeEngine: fakeEngine{fail: true}, uncertain: true}
	service := NewService(store, engine)
	defer service.Close()
	if r := request(service, "connect", profile.ID); r.Error == nil || r.Error.Code != "cleanup_incomplete" {
		t.Fatal("startup uncertainty lost")
	}
	if service.status().ProfileID != profile.ID || service.status().StartedAt != nil {
		t.Fatal("uncertain attempt has wrong identity or a false start time")
	}
	for _, method := range []string{"remove", "rollback"} {
		if r := request(service, method, profile.ID); r.Error == nil || r.Error.Code != "active_profile" {
			t.Fatal("uncertain initial profile was mutable", method)
		}
	}
	r := service.Handle(Request{Version: 1, ID: "update", Method: "import", Path: path, ProfileID: profile.ID, Digest: c.Profile.Digest})
	if r.Error == nil || r.Error.Code != "active_profile" {
		t.Fatal("uncertain initial profile was replaceable")
	}
}
