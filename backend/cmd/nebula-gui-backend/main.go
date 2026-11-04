package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"nebula-gui/backend/internal/client"
)

func main() { os.Exit(run()) }

func run() (exitCode int) {
	// This development binary is not an authorized privileged helper.
	if os.Geteuid() == 0 {
		fmt.Fprintln(os.Stderr, "This development backend must not run as root.")
		os.Exit(1)
	}
	if len(os.Args) < 2 || os.Args[1] != "serve" {
		fmt.Fprintln(os.Stderr, "usage: nebula-gui-backend serve --store /absolute/private/directory")
		os.Exit(2)
	}
	f := flag.NewFlagSet("serve", flag.ExitOnError)
	root := f.String("store", "", "private store directory")
	_ = f.Parse(os.Args[2:])
	store, err := client.NewStore(*root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "Cannot open private store; check ownership, permissions, and another running instance.")
		os.Exit(1)
	}
	defer store.Close()
	service := client.NewService(store, client.NewPrivilegedEngine())
	defer func() {
		if service.Close() != nil {
			exitCode = 1
		}
	}()
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	// Close stdin to let the serial loop perform orderly cleanup, avoiding concurrent Stop calls.
	go func() { <-signals; _ = os.Stdin.Close() }()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 32768)
	out := json.NewEncoder(os.Stdout)
	for scanner.Scan() {
		request, e := client.DecodeRequest(scanner.Bytes())
		if e != nil {
			_ = out.Encode(client.Response{Version: 1, ID: request.ID, Error: &client.Problem{Code: "invalid_request", Message: "请求无效。"}})
			continue
		}
		if out.Encode(service.Handle(request)) != nil {
			return 1
		}
	}
	return 0
}
