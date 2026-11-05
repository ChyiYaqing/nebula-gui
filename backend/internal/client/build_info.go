package client

import "runtime"

var ApplicationVersion = "development"
var BuildNumber = "0"

type BuildInfo struct {
	Component          string `json:"component"`
	ApplicationVersion string `json:"applicationVersion"`
	BuildNumber        string `json:"buildNumber"`
	ProtocolVersion    int    `json:"protocolVersion"`
	KernelRevision     string `json:"kernelRevision"`
	HelperRelease      string `json:"helperRelease"`
	GoVersion          string `json:"goVersion"`
	Architecture       string `json:"architecture"`
}

// Offline constants only: never opens a store, socket or network interface.
func BuildInformation(component string) BuildInfo {
	return BuildInfo{component, ApplicationVersion, BuildNumber, ProtocolVersion, KernelRevision, HelperRelease, runtime.Version(), runtime.GOARCH}
}
