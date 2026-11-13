//go:build !darwin

package client

func otherNebulaRunning() bool { return false }
