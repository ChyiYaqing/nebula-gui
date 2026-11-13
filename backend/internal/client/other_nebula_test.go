package client

import (
	"errors"
	"testing"
	"time"
)

type nebulaStartEngine struct {
	uncertainEngine
	startErr error
}

func (e *nebulaStartEngine) Start(data []byte) error {
	if e.startErr != nil {
		e.starts++
		return e.startErr
	}
	return e.fakeEngine.Start(data)
}

func TestServiceConnectOtherNebula(t *testing.T) {
	startFailure := &Problem{Code: "start_failed", Message: "original start failure"}
	authorizationFailure := &Problem{Code: "authorization_required", Message: "permission denied"}
	const hint = "检测到本机另有一个 Nebula 进程在运行，它可能占用了同一网络或端口，连接未能建立。请先停用它（例如旧的命令行或系统服务部署），再重新连接。"
	for _, tt := range []struct {
		name      string
		startErr  error
		other     bool
		uncertain bool
		wantCode  string
		wantCalls int
	}{
		{name: "start failed with other Nebula", startErr: startFailure, other: true, wantCode: "other_nebula_running", wantCalls: 1},
		{name: "start failed without other Nebula", startErr: startFailure, wantCode: "start_failed", wantCalls: 1},
		{name: "unstructured start failure", startErr: errors.New("test start failure"), other: true, wantCode: "other_nebula_running", wantCalls: 1},
		{name: "successful start skips check", other: true},
		{name: "other failure skips check", startErr: authorizationFailure, other: true, wantCode: "authorization_required"},
		{name: "cleanup failure takes precedence", startErr: startFailure, other: true, uncertain: true, wantCode: "cleanup_incomplete"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			store := openStore(t)
			candidate, err := Inspect(fixture(t), "", nil, time.Now())
			if err != nil {
				t.Fatal(err)
			}
			profile, err := store.Save(candidate, "")
			if err != nil {
				t.Fatal(err)
			}
			engine := &nebulaStartEngine{startErr: tt.startErr}
			engine.uncertain = tt.uncertain
			service := NewService(store, engine)
			defer service.Close()
			calls := 0
			service.otherNebula = func() bool {
				calls++
				return tt.other
			}
			response := request(service, "connect", profile.ID)
			if calls != tt.wantCalls {
				t.Fatalf("process checks = %d, want %d", calls, tt.wantCalls)
			}
			if engine.starts != 1 {
				t.Fatalf("starts = %d, want 1", engine.starts)
			}
			state := service.status()
			if tt.wantCode == "" {
				if response.Error != nil || state.State != "started" {
					t.Fatalf("successful connect changed: response=%+v, state=%+v", response, state)
				}
				return
			}
			if response.Error == nil || response.Error.Code != tt.wantCode {
				t.Fatalf("error = %v, want %s", response.Error, tt.wantCode)
			}
			if state.State != "failed" || state.Error == nil || state.Error.Code != tt.wantCode {
				t.Fatalf("failure not retained in status: %+v", state)
			}
			if tt.wantCode == "other_nebula_running" && response.Error.Message != hint {
				t.Fatalf("unexpected hint: %q", response.Error.Message)
			}
			if tt.wantCode == "start_failed" && response.Error != startFailure || tt.wantCode == "authorization_required" && response.Error != authorizationFailure {
				t.Fatal("original problem was replaced")
			}
			if tt.uncertain && (state.ProfileID != profile.ID || state.StartedAt != nil) {
				t.Fatalf("cleanup protection changed: %+v", state)
			}
			if events := service.events; len(events) != 1 || events[0].Code != tt.wantCode {
				t.Fatalf("events = %+v, want %s", events, tt.wantCode)
			}
		})
	}
}
