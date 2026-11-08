package client

import (
	"context"
	"encoding/json"
	"errors"
	"net/netip"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// Service is owned by one serial request loop. No externally reachable listener exists.
type Service struct {
	store     *Store
	engine    Engine
	active    string
	failure   *Problem
	events    []Event
	startedAt *time.Time
	lastProbe time.Time
	probe     func(context.Context, string, netip.Addr) (ProbeResult, error)
}

func NewService(s *Store, e Engine) *Service { return &Service{store: s, engine: e, events: []Event{}} }
func (s *Service) Close() error              { err := stopEngine(s.engine); s.active = ""; return err }
func stopEngine(e Engine) error {
	if checked, ok := e.(interface{ StopChecked() error }); ok {
		return checked.StopChecked()
	}
	e.Stop()
	return nil
}
func (s *Service) prune() {
	if err := s.store.Prune(s.active); err != nil {
		if len(s.events) == 0 || s.events[len(s.events)-1].Code != "profile_cleanup_pending" {
			s.event("profile_cleanup_pending")
		}
	}
}
func (s *Service) event(code string) {
	s.events = append(s.events, Event{time.Now().UTC(), code})
	if len(s.events) > 100 {
		s.events = append([]Event(nil), s.events[len(s.events)-100:]...)
	}
}
func (s *Service) status() Status {
	state := "disconnected"
	if s.active != "" {
		if s.engine.Alive() {
			state = "started"
		} else {
			if err := stopEngine(s.engine); err != nil {
				s.failure = &Problem{Code: "cleanup_incomplete", Message: "无法确认隧道已清理，请保留当前配置并检查后台状态。"}
				if len(s.events) == 0 || s.events[len(s.events)-1].Code != "cleanup_incomplete" {
					s.event("cleanup_incomplete")
				}
			} else {
				s.active = ""
				s.startedAt = nil
				s.failure = &Problem{Code: "backend_stopped", Message: "连接后台已停止，请重新连接。"}
				s.event("backend_stopped")
			}
		}
	}
	if s.failure != nil {
		state = "failed"
	}
	return Status{State: state, ProfileID: s.active, Error: s.failure, Peers: sortedPeers(s.engine.Peers()), StartedAt: s.startedAt, ObservedAt: time.Now().UTC()}
}

// sortedPeers gives a stable order: the kernel lists hosts by Go map iteration,
// so an unchanged hostmap would otherwise look changed on every 3 s poll and
// re-render the GUI. Established tunnels first, then by address and name.
func sortedPeers(peers []Peer) []Peer {
	key := func(p Peer) string {
		if len(p.Addresses) == 0 {
			return ""
		}
		return p.Addresses[0]
	}
	sort.SliceStable(peers, func(i, j int) bool {
		a, b := peers[i], peers[j]
		if a.Pending != b.Pending {
			return !a.Pending
		}
		if ka, kb := key(a), key(b); ka != kb {
			return ka < kb
		}
		return a.Name < b.Name
	})
	return peers
}
func (s *Service) Handle(r Request) Response {
	res := Response{Version: ProtocolVersion, ID: r.ID}
	if r.Version != ProtocolVersion {
		res.Error = &Problem{Code: "protocol_mismatch", Message: "界面与后台协议不兼容，请重新构建应用。"}
		return res
	}
	result, err := s.invoke(r)
	if err != nil {
		var p *Problem
		if errors.As(err, &p) {
			res.Error = p
		} else {
			res.Error = &Problem{Code: "storage_error", Message: "无法访问受管数据，请检查目录权限或重新启动应用。"}
		}
		s.event(res.Error.Code)
	} else {
		res.Result = result
	}
	return res
}
func (s *Service) invoke(r Request) (any, error) {
	switch r.Method {
	case "authorization":
		if e, ok := s.engine.(interface{ Authorization() AuthorizationStatus }); ok {
			return e.Authorization(), nil
		}
		return AuthorizationStatus{Reason: "not_installed"}, nil
	case "events":
		return append([]Event{}, s.events...), nil
	case "logs":
		// Live view only: kernel logs stay out of diagnostics, which excludes peer addresses.
		if source, ok := s.engine.(logSource); ok {
			if puller, ok := s.engine.(interface{ PullLogs() }); ok {
				puller.PullLogs()
			}
			return LogPage{Available: true, Entries: source.LogsSince(0)}, nil
		}
		return LogPage{Available: false, Entries: []LogEntry{}}, nil
	case "list":
		s.prune()
		return s.store.List()
	case "rename":
		profile, err := s.store.Rename(r.ProfileID, r.Name)
		if err == nil {
			s.event("profile_renamed")
		}
		return profile, err
	case "preview", "import":
		name := r.Name
		if r.Method == "import" && r.ProfileID != "" && strings.TrimSpace(name) == "" {
			current, _, err := s.store.Load(r.ProfileID)
			if err != nil {
				return nil, err
			}
			name = current.Name
		}
		c, err := Inspect(r.Path, name, r.Files, time.Now())
		if err != nil {
			return nil, err
		}
		if r.Method == "preview" {
			return c.Profile, nil
		}
		if r.Digest == "" || c.Profile.Digest != r.Digest {
			return nil, problem("source_changed", "配置或凭据已改变，请重新检查后确认导入。", "config")
		}
		if r.ProfileID != "" && r.ProfileID == s.status().ProfileID {
			return nil, problem("active_profile", "请先断开该网络，再更新配置。", "profileID")
		}
		p, err := s.store.Save(c, r.ProfileID)
		if err == nil {
			s.event("profile_imported")
			s.prune()
		}
		return p, err
	case "remove", "rollback":
		if r.ProfileID != "" && r.ProfileID == s.status().ProfileID {
			return nil, problem("active_profile", "请先断开该网络。", "profileID")
		}
		if r.Method == "rollback" {
			return s.store.Rollback(r.ProfileID)
		}
		return map[string]bool{"removed": true}, s.store.Remove(r.ProfileID)
	case "connect":
		status := s.status()
		if status.ProfileID != "" {
			if s.failure != nil {
				return nil, s.failure
			}
			if status.ProfileID == r.ProfileID {
				return status, nil
			}
			return nil, problem("already_connected", "请先断开当前网络，再切换配置。", "profileID")
		}
		p, _, err := s.store.Load(r.ProfileID)
		if err != nil {
			return nil, err
		}
		dir, err := s.store.versionDir(p.ID, p.Version)
		if err != nil {
			return nil, err
		}
		c, err := Inspect(filepath.Join(dir, "config.yaml"), p.Name, nil, time.Now())
		if err != nil {
			return nil, err
		}
		if c.Profile.Digest != p.Digest {
			return nil, problem("source_changed", "受管配置已改变，请重新导入。", "config")
		}
		s.failure = nil
		if err = s.engine.Start(c.Config); err != nil {
			if stopErr := stopEngine(s.engine); stopErr != nil {
				err = stopErr
			}
			var issue *Problem
			if !errors.As(err, &issue) {
				issue = &Problem{Code: "start_failed", Message: "连接失败。"}
			}
			s.failure = issue
			if issue.Code == "cleanup_incomplete" {
				s.active = p.ID
				s.startedAt = nil
			}
			return nil, issue
		}
		s.active = p.ID
		started := time.Now().UTC()
		s.startedAt = &started
		s.event("tunnel_started")
		return s.status(), nil
	case "disconnect":
		if err := stopEngine(s.engine); err != nil {
			s.failure = &Problem{Code: "cleanup_incomplete", Message: "无法确认隧道已清理，请保留当前配置并检查后台状态。"}
			return nil, s.failure
		}
		s.active = ""
		s.startedAt = nil
		s.failure = nil
		s.event("tunnel_stopped")
		s.prune()
		return s.status(), nil
	case "probe":
		state := s.status()
		if state.State != "started" {
			return nil, problem("not_connected", "请先连接网络，再测试节点。", "")
		}
		profile, _, err := s.store.Load(s.active)
		if err != nil {
			return nil, err
		}
		address, err := validateProbeTarget(r.Address, profile.Networks)
		if err != nil {
			return nil, err
		}
		if time.Since(s.lastProbe) < 3*time.Second {
			return nil, problem("probe_rate_limited", "请稍候再测试节点。", "")
		}
		s.lastProbe = time.Now()
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		defer cancel()
		probe := s.probe
		if probe == nil {
			probe = probeNode
		}
		local, _ := probeSource(address, profile.Networks) // validateProbeTarget found the matching network.
		result, err := probe(ctx, address.String(), local)
		if err == nil {
			s.event("node_probe_finished")
		}
		return result, err
	case "recover":
		worker, ok := s.engine.(interface{ RecoverChecked() error })
		if !ok {
			return nil, problem("unsupported", "此后台不支持恢复确认。", "")
		}
		if err := worker.RecoverChecked(); err != nil {
			return nil, err
		}
		s.active = ""
		s.startedAt = nil
		s.failure = nil
		s.event("cleanup_confirmed")
		s.prune()
		return s.status(), nil
	case "rebind":
		if s.status().State != "started" {
			return nil, problem("not_connected", "请先连接网络。", "")
		}
		worker, ok := s.engine.(interface{ Rebind() error })
		if !ok {
			return nil, problem("unsupported", "此后台不支持网络刷新。", "")
		}
		if err := worker.Rebind(); err != nil {
			return nil, err
		}
		s.event("network_refresh_requested")
		return s.status(), nil
	case "status":
		return s.status(), nil
	case "diagnostics":
		// Schema is an allowlist: no paths, YAML, credential material, names or peer IPs.
		status := s.status()
		profiles, err := s.store.List()
		if err != nil {
			return nil, err
		}
		return map[string]any{"schema": 1, "kernelRevision": KernelRevision, "state": status.State, "profileCount": len(profiles), "knownPeerCount": len(status.Peers), "events": s.events, "generatedAt": time.Now().UTC()}, nil
	default:
		return nil, problem("unknown_method", "后台不支持此操作。", "")
	}
}
func DecodeRequest(b []byte) (Request, error) {
	var r Request
	// Decode once into a map to reject unknown fields without including their values in errors.
	var fields map[string]json.RawMessage
	if json.Unmarshal(b, &fields) != nil || fields == nil {
		return r, problem("invalid_request", "请求不是有效 JSON 对象。", "")
	}
	for k := range fields {
		switch k {
		case "version", "id", "method", "path", "profileID", "name", "digest", "files", "address":
		default:
			return r, problem("invalid_request", "请求包含未知字段。", "")
		}
	}
	if json.Unmarshal(b, &r) != nil || len(r.ID) > 80 || len(r.Path) > 4096 || len(r.Name) > 160 || len(r.Files) > 3 || len(r.Address) > 64 {
		return r, problem("invalid_request", "请求字段无效或过长。", "")
	}
	for k, v := range r.Files {
		if (k != "ca" && k != "cert" && k != "key") || len(v) > 4096 {
			return r, problem("invalid_request", "补选文件字段无效。", "")
		}
	}
	return r, nil
}
