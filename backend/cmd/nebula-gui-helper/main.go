package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"nebula-gui/backend/internal/client"
	"os"
)

func main() {
	metadata := flag.Bool("metadata", false, "print offline build information without opening a socket")
	health := flag.Bool("health", false, "check the installed helper without privileges")
	uid := flag.Uint("uid", 0, "one authorized non-root user")
	flag.Parse()
	if *metadata {
		if json.NewEncoder(os.Stdout).Encode(client.BuildInformation("helper")) != nil {
			os.Exit(1)
		}
		return
	}
	if *health {
		state := client.NewPrivilegedEngine().Authorization()
		if !state.Available || state.UpdateRequired {
			os.Exit(1)
		}
		return
	}
	if *uid == 0 || uint64(*uid) > uint64(^uint32(0)) {
		fmt.Fprintln(os.Stderr, "invalid authorized user")
		os.Exit(2)
	}
	if err := client.ServePrivilegedHelper(uint32(*uid)); err != nil {
		fmt.Fprintln(os.Stderr, "helper stopped or installation validation failed")
		os.Exit(1)
	}
}
