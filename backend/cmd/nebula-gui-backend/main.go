package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"nebula-gui/backend/internal/client"
)

func main() { os.Exit(run()) }

func run() int {
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
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(signals)
	// Close stdin to let the serial loop perform orderly cleanup, avoiding concurrent Stop calls.
	go func() { <-signals; _ = os.Stdin.Close() }()
	return serve(*root, func(store *client.Store) *client.Service {
		return client.NewService(store, client.NewPrivilegedEngine())
	}, os.Stdin, os.Stdout)
}

// serve answers requests in order. Until the private store opens, each request gets a
// structured problem and the next one retries, so a second instance recovers once the
// first quits. Exiting instead looked like a crash to the GUI, which then reported an
// unconfirmed tunnel cleanup although nothing could have started (#84).
func serve(root string, newService func(*client.Store) *client.Service, in io.Reader, w io.Writer) (exitCode int) {
	var store *client.Store
	var service *client.Service
	defer func() {
		if service != nil && service.Close() != nil {
			exitCode = 1
		}
		if store != nil {
			store.Close()
		}
	}()
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 4096), 32768)
	out := json.NewEncoder(w)
	for scanner.Scan() {
		request, e := client.DecodeRequest(scanner.Bytes())
		if e != nil {
			_ = out.Encode(client.Response{Version: 1, ID: request.ID, Error: &client.Problem{Code: "invalid_request", Message: "请求无效。"}})
			continue
		}
		if service == nil {
			opened, err := client.NewStore(root)
			if err != nil {
				if out.Encode(client.Response{Version: 1, ID: request.ID, Error: storeProblem(err)}) != nil {
					return 1
				}
				continue
			}
			store, service = opened, newService(opened)
		}
		if out.Encode(service.Handle(request)) != nil {
			return 1
		}
	}
	return 0
}

func storeProblem(err error) *client.Problem {
	if errors.Is(err, client.ErrStoreInUse) {
		return &client.Problem{Code: "store_in_use", Message: "另一个 Nebula 正在使用同一份数据。请先退出另一个 Nebula，此窗口会自动恢复。"}
	}
	return &client.Problem{Code: "store_unavailable", Message: "无法打开 Nebula 的数据目录：它必须属于当前用户且仅当前用户可访问。请检查目录权限后重试。"}
}
