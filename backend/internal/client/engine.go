package client

import (
	"io"
	"log/slog"
	"strings"

	"github.com/slackhq/nebula"
	"github.com/slackhq/nebula/config"
	"github.com/slackhq/nebula/logging"
)

type Engine interface {
	Start([]byte) error
	Stop()
	Alive() bool
	Peers() []Peer
}
type NativeEngine struct {
	control *nebula.Control
	logs    *logRing
}

// logSource is implemented by engines that can supply redacted kernel logs.
type logSource interface{ LogsSince(after uint64) []LogEntry }

// LogsSince keeps returning earlier sessions' entries, so a failed start stays visible.
func (e *NativeEngine) LogsSince(after uint64) []LogEntry {
	if e.logs == nil {
		return []LogEntry{}
	}
	return e.logs.since(after)
}

func (e *NativeEngine) Start(data []byte) error {
	c := config.NewC(logging.NewLogger(io.Discard))
	if c.LoadString(string(data)) != nil {
		return problem("invalid_config", "无法读取受管配置。", "config")
	}
	if e.logs == nil {
		e.logs = &logRing{}
	}
	control, err := nebula.Main(c, false, "nebula-gui/"+KernelRevision, slog.New(newRingHandler(e.logs)), nil)
	if err != nil {
		// Raw kernel errors can contain user-supplied values: never forward them to UI/logs.
		message := strings.ToLower(err.Error())
		if strings.Contains(message, "permission") || strings.Contains(message, "not permitted") {
			return problem("authorization_required", "系统拒绝创建隧道。此本机验证版尚未安装已授权后台；配置已保存。", "")
		}
		return problem("start_failed", "Nebula 无法启动，请检查网络参数、端口占用和系统权限。", "")
	}
	if err = control.Start(); err != nil {
		control.Stop()
		return problem("start_failed", "Nebula 启动失败，已清理本次连接。", "")
	}
	e.control = control
	return nil
}
func (e *NativeEngine) Rebind() error {
	if !e.Alive() {
		return problem("not_connected", "当前没有可刷新的连接。", "")
	}
	e.control.RebindUDPServer()
	return nil
}
func (e *NativeEngine) Stop() {
	if e.control != nil {
		e.control.Stop()
		_ = e.control.Wait()
		e.control = nil
	}
}
func (e *NativeEngine) Alive() bool {
	return e.control != nil && e.control.State() == nebula.StateStarted
}
func (e *NativeEngine) Peers() []Peer {
	peers := []Peer{}
	if !e.Alive() {
		return peers
	}
	for _, pending := range []bool{false, true} {
		for _, h := range e.control.ListHostmapHosts(pending) {
			p := Peer{Addresses: []string{}, Pending: pending}
			if h.Cert != nil {
				p.Name = h.Cert.Name()
			}
			for _, ip := range h.VpnAddrs {
				p.Addresses = append(p.Addresses, ip.String())
			}
			peers = append(peers, p)
		}
	}
	return peers
}
