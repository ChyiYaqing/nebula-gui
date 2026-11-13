package client

import "testing"

func TestOtherNebulaProcessName(t *testing.T) {
	for _, tt := range []struct {
		name string
		pid  int
		want bool
	}{
		{name: "nebula", pid: 2, want: true},
		{name: "Nebula", pid: 2, want: true},
		{name: "nebula", pid: 1},
		{name: "nebula-gui-backe", pid: 2},
		{name: "nebula-gui-helpe", pid: 2},
		{name: "nebula-gui-backend", pid: 2},
		{name: "nebula-gui-helper", pid: 2},
		{name: "NebulaGUI", pid: 2},
		{name: "nebula-cert", pid: 2},
		{name: "", pid: 2},
	} {
		if got := isOtherNebulaProcess(tt.name, tt.pid, 1); got != tt.want {
			t.Errorf("isOtherNebulaProcess(%q, %d, 1) = %v, want %v", tt.name, tt.pid, got, tt.want)
		}
	}
}
