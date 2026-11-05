package client

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

const HelperRelease = "0.3.1"

const HelperSocket = "/private/var/run/nebula-gui/helper.sock"
const HelperExecutable = "/Library/PrivilegedHelperTools/net.nebula.gui/nebula-gui-helper"
const HelperLabel = "net.nebula.gui.helper"
const helperMaxFrame = 3 << 20

type AuthorizationStatus struct {
	Available      bool   `json:"available"`
	Revision       string `json:"revision,omitempty"`
	Reason         string `json:"reason,omitempty"`
	HelperRelease  string `json:"helperRelease,omitempty"`
	UpdateRequired bool   `json:"updateRequired"`
}
type helperRequest struct {
	Version int    `json:"version"`
	ID      string `json:"id"`
	Method  string `json:"method"`
	Config  string `json:"config,omitempty"`
}
type helperReply struct {
	Version       int      `json:"version"`
	ID            string   `json:"id"`
	Revision      string   `json:"revision"`
	Started       bool     `json:"started"`
	Peers         []Peer   `json:"peers"`
	Error         *Problem `json:"error,omitempty"`
	HelperRelease string   `json:"helperRelease,omitempty"`
	Clean         bool     `json:"clean,omitempty"`
}

func peerUID(conn *net.UnixConn) (uint32, error) {
	raw, err := conn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var uid uint32
	var credentialErr error
	err = raw.Control(func(fd uintptr) {
		cred, e := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		credentialErr = e
		if e == nil {
			uid = cred.Uid
		}
	})
	if err != nil {
		return 0, err
	}
	return uid, credentialErr
}
func secureDirectory(path string, uid uint32) error {
	var st unix.Stat_t
	if unix.Lstat(path, &st) != nil || st.Mode&unix.S_IFMT != unix.S_IFDIR || st.Mode&0022 != 0 || st.Uid != uid {
		return errors.New("untrusted directory")
	}
	return nil
}
func helperUnavailable() error {
	return problem("authorization_required", "需要先启用连接后台，再连接网络。", "")
}

// PrivilegedEngine only sends validated inline config, never commands or file paths.
// A root helper owns the tunnel only while this authenticated connection is alive.
type PrivilegedEngine struct {
	socket        string
	serverUID     uint32
	conn          *net.UnixConn
	reader        *bufio.Reader
	nextID        uint64
	warning       error
	helperRelease string
}

func NewPrivilegedEngine() *PrivilegedEngine {
	return &PrivilegedEngine{socket: HelperSocket, serverUID: 0}
}
func (e *PrivilegedEngine) dial() (*net.UnixConn, error) {
	if secureDirectory(filepath.Dir(e.socket), e.serverUID) != nil {
		return nil, helperUnavailable()
	}
	conn, err := net.DialTimeout("unix", e.socket, time.Second)
	if err != nil {
		return nil, helperUnavailable()
	}
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		conn.Close()
		return nil, helperUnavailable()
	}
	uid, err := peerUID(unixConn)
	if err != nil || uid != e.serverUID {
		conn.Close()
		return nil, problem("untrusted_helper", "连接后台身份无法验证，已拒绝连接。", "")
	}
	return unixConn, nil
}
func helperExchange(conn *net.UnixConn, reader *bufio.Reader, r helperRequest) (helperReply, error) {
	var reply helperReply
	deadline := 10 * time.Second
	if r.Method == "health" {
		deadline = time.Second
	}
	if err := conn.SetDeadline(time.Now().Add(deadline)); err != nil {
		return reply, err
	}
	if err := json.NewEncoder(conn).Encode(r); err != nil {
		return reply, err
	}
	b, err := readHelperFrame(reader)
	if err != nil {
		return reply, err
	}
	if json.Unmarshal(b, &reply) != nil || reply.Version != 1 || reply.ID != r.ID || reply.Revision != KernelRevision {
		return reply, problem("helper_mismatch", "连接后台版本不匹配，请重新授权安装。", "")
	}
	if reply.Error != nil {
		return reply, reply.Error
	}
	return reply, nil
}
func (e *PrivilegedEngine) Authorization() AuthorizationStatus {
	conn, err := e.dial()
	if err != nil {
		return AuthorizationStatus{Reason: "not_installed"}
	}
	defer conn.Close()
	reply, err := helperExchange(conn, bufio.NewReader(conn), helperRequest{Version: 1, ID: "health", Method: "health"})
	if err != nil {
		return AuthorizationStatus{Reason: "unavailable"}
	}
	return AuthorizationStatus{Available: true, Revision: reply.Revision, HelperRelease: reply.HelperRelease, UpdateRequired: reply.HelperRelease != HelperRelease}
}
func (e *PrivilegedEngine) exchange(method, config string) (helperReply, error) {
	if e.conn == nil {
		return helperReply{}, helperUnavailable()
	}
	e.nextID++
	return helperExchange(e.conn, e.reader, helperRequest{Version: 1, ID: stringID(e.nextID), Method: method, Config: config})
}
func stringID(n uint64) string { return time.Unix(0, int64(n)).UTC().Format("150405.000000000") }
func (e *PrivilegedEngine) Start(data []byte) error {
	if e.warning != nil {
		return e.warning
	}
	conn, err := e.dial()
	if err != nil {
		return err
	}
	e.conn = conn
	e.reader = bufio.NewReader(conn)
	reply, err := e.exchange("connect", string(data))
	e.helperRelease = reply.HelperRelease
	if err != nil || !reply.Started {
		e.conn.Close()
		e.conn = nil
		e.reader = nil
		if err != nil {
			// A definite rejection carries a helper Problem and proves no tunnel was accepted.
			// Transport/protocol failures after connect are uncertain until the owner session cleans up.
			if reply.Error != nil {
				return reply.Error
			}
			e.warning = problem("cleanup_incomplete", "连接后台的启动结果不确定，已关闭控制会话；请先检查隧道清理状态。", "")
			return e.warning
		}
		return problem("start_failed", "连接后台未能启动隧道。", "")
	}
	return nil
}

// RecoverChecked clears uncertainty only after the authenticated component proves
// no previous controller still owns a tunnel. It never disconnects another owner.
func (e *PrivilegedEngine) RecoverChecked() error {
	e.warning = problem("cleanup_incomplete", "旧连接尚未获得清理确认。", "")
	if e.conn != nil {
		e.conn.Close()
		e.conn = nil
		e.reader = nil
	}
	conn, err := e.dial()
	if err != nil {
		return err
	}
	defer conn.Close()
	reply, err := helperExchange(conn, bufio.NewReader(conn), helperRequest{Version: 1, ID: "recover", Method: "confirm_cleanup"})
	if err != nil {
		// Transport/protocol failure is uncertainty, not evidence of an old
		// component. Only a correlated, valid reply can identify its version.
		if reply.Version != 1 || reply.ID != "recover" || reply.Revision != KernelRevision {
			return problem("cleanup_incomplete", "未收到有效的清理确认，请稍后重试。", "")
		}
		if reply.HelperRelease != HelperRelease {
			return problem("helper_upgrade_required", "请先升级连接后台，再恢复连接。", "")
		}
		return err
	}
	if reply.HelperRelease != HelperRelease {
		return problem("helper_upgrade_required", "请先升级连接后台，再恢复连接。", "")
	}
	if !reply.Clean {
		return problem("cleanup_pending", "旧连接仍在清理，请稍后重试。", "")
	}
	e.warning = nil
	return nil
}
func (e *PrivilegedEngine) Rebind() error {
	if e.helperRelease != HelperRelease {
		return problem("helper_upgrade_required", "网络恢复功能需要升级连接后台。", "")
	}
	_, err := e.exchange("rebind", "")
	return err
}
func (e *PrivilegedEngine) Stop() { _ = e.StopChecked() }
func (e *PrivilegedEngine) StopChecked() error {
	if e.conn == nil {
		return e.warning
	}
	_, err := e.exchange("disconnect", "")
	e.conn.Close()
	e.conn = nil
	e.reader = nil
	if err != nil {
		e.warning = problem("cleanup_incomplete", "无法确认连接后台已清理隧道，请检查后台状态。", "")
	}
	return e.warning
}
func (e *PrivilegedEngine) Alive() bool {
	if e.conn == nil {
		return false
	}
	r, err := e.exchange("status", "")
	return err == nil && r.Started
}
func (e *PrivilegedEngine) Peers() []Peer {
	if e.conn == nil {
		return []Peer{}
	}
	r, err := e.exchange("status", "")
	if err != nil {
		return []Peer{}
	}
	return r.Peers
}
func readHelperFrame(reader *bufio.Reader) ([]byte, error) {
	var frame []byte
	for {
		part, err := reader.ReadSlice('\n')
		if len(frame)+len(part) > helperMaxFrame {
			return nil, errors.New("frame too large")
		}
		frame = append(frame, part...)
		if err == nil {
			return frame, nil
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return nil, err
		}
	}
}
func decodeHelperRequest(data []byte) (helperRequest, error) {
	var r helperRequest
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&r); err != nil {
		return r, errors.New("invalid request")
	}
	var extra any
	if dec.Decode(&extra) != io.EOF || r.Version != 1 || len(r.ID) > 80 || len(r.Config) > 2<<20 {
		return r, errors.New("invalid request")
	}
	if r.Method != "connect" && r.Method != "disconnect" && r.Method != "status" && r.Method != "health" && r.Method != "rebind" && r.Method != "confirm_cleanup" {
		return r, errors.New("unsupported operation")
	}
	if r.Method != "connect" && r.Config != "" {
		return r, errors.New("unexpected configuration")
	}
	return r, nil
}
func validateInline(data []byte, temporaryRoot string) (*Candidate, error) {
	m, err := parseConfig(data)
	if err != nil {
		return nil, err
	}
	if err = validatePolicy(m); err != nil {
		return nil, err
	}
	pki := section(m, "pki")
	for _, key := range []string{"ca", "cert", "key"} {
		value, ok := pki[key].(string)
		if !ok || !strings.HasPrefix(strings.TrimSpace(value), "-----BEGIN ") {
			return nil, problem("inline_required", "授权后台只接受内嵌凭据，不接受文件路径。", "pki."+key)
		}
	}
	// Disabled host DNS still has recovery hooks; no client-supplied recovery identity.
	if dns := section(m, "dns"); dns != nil {
		for key := range dns {
			if key != "enabled" {
				return nil, problem("unsupported", "授权后台不接受 DNS 参数。", "dns")
			}
		}
	}
	for _, field := range []string{"routines", "tun.tx_queue"} {
		value := m[field]
		limit := 16
		if field == "tun.tx_queue" {
			value = section(m, "tun")["tx_queue"]
			limit = 65536
		}
		if value != nil {
			n, ok := value.(int)
			if !ok || n < 1 || n > limit {
				return nil, problem("unsupported", "运行参数超出授权后台范围。", field)
			}
		}
	}
	f, err := os.CreateTemp(temporaryRoot, ".validate-*.yaml")
	if err != nil {
		return nil, err
	}
	path := f.Name()
	defer os.Remove(path)
	if _, err = f.Write(data); err != nil {
		f.Close()
		return nil, err
	}
	if err = f.Close(); err != nil {
		return nil, err
	}
	return Inspect(path, "", nil, time.Now())
}

// HelperServer authenticates the kernel-reported peer UID. One control session
// owns one tunnel; a dropped connection synchronously stops that tunnel.
type HelperServer struct {
	AllowedUID    uint32
	TemporaryRoot string
	NewEngine     func() Engine
	controller    sync.Mutex
	transition    sync.Mutex
	nextSession   atomic.Uint64
	cleanupFence  uint64
	beforeConnect func()
	sessions      sync.WaitGroup
	connections   sync.Map
}

func (s *HelperServer) Serve(listener *net.UnixListener) error {
	defer s.sessions.Wait()
	slots := make(chan struct{}, 8)
	for {
		conn, err := listener.AcceptUnix()
		if err != nil {
			s.connections.Range(func(key, value any) bool { key.(*net.UnixConn).Close(); return true })
			return err
		}
		select {
		case slots <- struct{}{}:
		default:
			conn.Close()
			continue
		}
		session := s.nextSession.Add(1)
		s.sessions.Add(1)
		s.connections.Store(conn, true)
		go func() {
			defer s.sessions.Done()
			defer func() { <-slots; s.connections.Delete(conn) }()
			s.handle(conn, session)
		}()
	}
}
func (s *HelperServer) handle(conn *net.UnixConn, session uint64) {
	defer conn.Close()
	defer func() {
		if recover() != nil {
			conn.Close()
		}
	}()
	uid, err := peerUID(conn)
	if err != nil || uid != s.AllowedUID {
		return
	}
	reader := bufio.NewReader(conn)
	var engine Engine
	ownsController := false
	defer func() {
		if ownsController {
			defer s.controller.Unlock()
			if engine != nil {
				engine.Stop()
			}
		}
	}()
	for {
		_ = conn.SetReadDeadline(time.Now().Add(30 * time.Second))
		data, err := readHelperFrame(reader)
		if err != nil {
			return
		}
		r, err := decodeHelperRequest(data)
		reply := helperReply{Version: 1, ID: r.ID, Revision: KernelRevision, Peers: []Peer{}, HelperRelease: HelperRelease}
		if err != nil {
			reply.Error = &Problem{Code: "invalid_request", Message: "授权后台拒绝了无效请求。"}
		} else {
			switch r.Method {
			case "health":
				if engine != nil {
					reply.Error = &Problem{Code: "invalid_request", Message: "连接会话不支持健康探测。"}
				}
			case "confirm_cleanup":
				s.transition.Lock()
				if ownsController || !s.controller.TryLock() {
					reply.Error = &Problem{Code: "cleanup_pending", Message: "已有连接仍在运行或清理。"}
				} else {
					// Any accepted but not-yet-started connect from before
					// this proof must never be allowed to start afterwards.
					s.cleanupFence = s.nextSession.Load()
					reply.Clean = true
					s.controller.Unlock()
				}
				s.transition.Unlock()
			case "rebind":
				if worker, ok := engine.(interface{ Rebind() error }); ok {
					if err := worker.Rebind(); err != nil {
						reply.Error = &Problem{Code: "rebind_failed", Message: "网络刷新请求未完成。"}
					}
				} else {
					reply.Error = &Problem{Code: "not_connected", Message: "当前没有可刷新的连接。"}
				}
			case "connect":
				if engine != nil {
					reply.Error = &Problem{Code: "already_connected", Message: "该会话已建立连接。"}
					break
				}
				if s.beforeConnect != nil {
					s.beforeConnect()
				}
				s.transition.Lock()
				if session <= s.cleanupFence {
					s.transition.Unlock()
					reply.Error = &Problem{Code: "cleanup_pending", Message: "旧连接请求已失效，请重新连接。"}
					break
				}
				if !s.controller.TryLock() {
					s.transition.Unlock()
					reply.Error = &Problem{Code: "already_connected", Message: "已有应用会话管理隧道，请先断开。"}
					break
				}
				ownsController = true
				s.transition.Unlock()
				engine = s.NewEngine()
				candidate, e := validateInline([]byte(r.Config), s.TemporaryRoot)
				if e == nil {
					e = engine.Start(candidate.Config)
				}
				if e != nil {
					var issue *Problem
					if errors.As(e, &issue) {
						reply.Error = issue
					} else {
						reply.Error = &Problem{Code: "start_failed", Message: "授权后台无法启动隧道。"}
					}
				} else {
					reply.Started = engine.Alive()
				}
			case "status":
				if engine != nil {
					reply.Started = engine.Alive()
					reply.Peers = engine.Peers()
				}
			case "disconnect":
				if engine != nil {
					engine.Stop()
					engine = nil
					ownsController = false
					s.controller.Unlock()
				}
			}
		}
		_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if json.NewEncoder(conn).Encode(reply) != nil {
			return
		}
		if r.Method == "health" || r.Method == "confirm_cleanup" || r.Method == "disconnect" || reply.Error != nil {
			return
		}
	}
}
func ServePrivilegedHelper(uid uint32) error {
	if os.Geteuid() != 0 || uid == 0 {
		return errors.New("helper requires root and one non-root controller")
	}
	executable, err := os.Executable()
	if err != nil || executable != HelperExecutable {
		return errors.New("helper must run from protected installation")
	}
	for path := filepath.Dir(executable); path != "/"; path = filepath.Dir(path) {
		if secureDirectory(path, 0) != nil {
			return errors.New("untrusted installation path")
		}
	}
	var st unix.Stat_t
	if unix.Lstat(executable, &st) != nil || st.Uid != 0 || st.Mode&0022 != 0 || st.Mode&unix.S_IFMT != unix.S_IFREG {
		return errors.New("untrusted helper executable")
	}
	dir := filepath.Dir(HelperSocket)
	if err = os.MkdirAll(dir, 0755); err != nil {
		return err
	}
	if secureDirectory(dir, 0) != nil {
		return errors.New("untrusted runtime path")
	}
	temporary := filepath.Join(dir, "private")
	if err = os.MkdirAll(temporary, 0700); err != nil {
		return err
	}
	if checkPrivateDirectory(temporary, 0) != nil {
		return errors.New("untrusted temporary path")
	}
	if existing, err := net.DialTimeout("unix", HelperSocket, time.Second); err == nil {
		existing.Close()
		return errors.New("helper already running")
	}
	if info, err := os.Lstat(HelperSocket); err == nil {
		if info.Mode()&os.ModeSocket == 0 {
			return errors.New("unexpected runtime file")
		}
		if err = os.Remove(HelperSocket); err != nil {
			return err
		}
	}
	// Create the socket as 0600, so no wider mode exists before secureSocket.
	mask := unix.Umask(0177)
	listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: HelperSocket, Net: "unix"})
	unix.Umask(mask)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(HelperSocket)
	if err = secureSocket(HelperSocket, uid); err != nil {
		return err
	}
	server := &HelperServer{AllowedUID: uid, TemporaryRoot: temporary, NewEngine: func() Engine { return &NativeEngine{} }}
	return runHelperUntilSignal(server, listener)
}

// secureSocket hands the control socket to its controller. The runtime parent
// is writable by group daemon, so a planted link must not redirect root's changes.
func secureSocket(path string, uid uint32) error {
	if err := unix.Fchownat(unix.AT_FDCWD, path, int(uid), -1, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	if err := unix.Fchmodat(unix.AT_FDCWD, path, 0600, unix.AT_SYMLINK_NOFOLLOW); err != nil {
		return err
	}
	var st unix.Stat_t
	if unix.Lstat(path, &st) != nil || st.Mode&unix.S_IFMT != unix.S_IFSOCK || st.Uid != uid || st.Mode&0777 != 0600 {
		return errors.New("untrusted control socket")
	}
	return nil
}
