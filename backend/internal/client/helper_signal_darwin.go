package client

import (
	"net"
	"os"
	"os/signal"
	"syscall"
)

func runHelperUntilSignal(server *HelperServer, listener *net.UnixListener) error {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		select {
		case <-signals:
			listener.Close()
		case <-finished:
		}
	}()
	return server.Serve(listener)
}
