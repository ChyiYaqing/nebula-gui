package client

import (
	"os"
	"strings"

	"golang.org/x/sys/unix"
)

func otherNebulaRunning() bool {
	processes, err := unix.SysctlKinfoProcSlice("kern.proc.all")
	if err != nil {
		return false
	}
	currentPID := os.Getpid()
	for _, process := range processes {
		if isOtherNebulaProcess(unix.ByteSliceToString(process.Proc.P_comm[:]), int(process.Proc.P_pid), currentPID) {
			return true
		}
	}
	return false
}

func isOtherNebulaProcess(name string, pid, currentPID int) bool {
	return pid != currentPID && strings.EqualFold(name, "nebula")
}
