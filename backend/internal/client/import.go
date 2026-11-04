package client

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/slackhq/nebula"
	"github.com/slackhq/nebula/cert"
	"github.com/slackhq/nebula/config"
	"github.com/slackhq/nebula/logging"
	"go.yaml.in/yaml/v3"
	"golang.org/x/sys/unix"
)

const maxFileSize = 2 << 20

// No symlinks or special files: inputs must be explicitly selected regular files.
func readPrivateInput(path string) ([]byte, error) {
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), path)
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Size() > maxFileSize {
		return nil, errors.New("not a bounded regular file")
	}
	b, err := io.ReadAll(io.LimitReader(f, maxFileSize+1))
	if len(b) > maxFileSize {
		return nil, errors.New("file too large")
	}
	return b, err
}
func parseConfig(b []byte) (map[string]any, error) {
	d := yaml.NewDecoder(bytes.NewReader(b))
	var n yaml.Node
	if d.Decode(&n) != nil {
		return nil, problem("invalid_yaml", "配置不是有效的 YAML。", "config")
	}
	var check func(*yaml.Node, int) bool
	check = func(n *yaml.Node, depth int) bool {
		if depth > 48 || n.Kind == yaml.AliasNode {
			return false
		}
		for _, c := range n.Content {
			if !check(c, depth+1) {
				return false
			}
		}
		return true
	}
	if !check(&n, 0) {
		return nil, problem("invalid_yaml", "配置层级过深或包含不支持的 YAML 别名。", "config")
	}
	var m map[string]any
	if n.Decode(&m) != nil || m == nil {
		return nil, problem("invalid_yaml", "配置必须是没有重复字段的 YAML 对象。", "config")
	}
	var extra yaml.Node
	if d.Decode(&extra) != io.EOF {
		return nil, problem("invalid_yaml", "配置只能包含一个 YAML 文档。", "config")
	}
	return m, nil
}
func section(m map[string]any, key string) map[string]any { v, _ := m[key].(map[string]any); return v }
func validatePolicy(m map[string]any) error {
	allowed := map[string]bool{}
	for _, k := range strings.Fields("pki static_host_map lighthouse listen punchy relay tun firewall logging cipher preferred_ranges routines handshakes connection_manager calculated_remotes local_allow_list remote_allow_list sshd stats dns local_api") {
		allowed[k] = true
	}
	for key := range m {
		if !allowed[key] {
			return problem("unsupported", "配置包含首版不支持的顶层字段。", key)
		}
	}
	for _, key := range []string{"pki", "lighthouse", "listen", "punchy", "relay", "tun", "firewall", "logging", "sshd", "stats", "dns", "local_api"} {
		if v, ok := m[key]; ok && v != nil && section(m, key) == nil {
			return problem("invalid_config", "该配置字段必须是对象。", key)
		}
	}
	for scope, keys := range map[string][]string{"tun": {"unsafe_routes", "routes"}, "pki": {"pkcs11"}} {
		for _, key := range keys {
			if v, exists := section(m, scope)[key]; exists && v != nil {
				if list, ok := v.([]any); !ok || len(list) != 0 {
					return problem("unsupported", "该设置超出仅连接 Nebula 节点的范围。", scope+"."+key)
				}
			}
		}
	}
	for scope, key := range map[string]string{"dns": "enabled", "sshd": "enabled", "lighthouse": "am_lighthouse", "relay": "am_relay", "tun": "disabled"} {
		if v, ok := section(m, scope)[key]; ok && v != false {
			return problem("unsupported", "首版不启用该功能。", scope+"."+key)
		}
	}
	if v := section(m, "stats")["type"]; v != nil && v != "" && v != "none" {
		return problem("unsupported", "首版不启动额外指标服务。", "stats.type")
	}
	if v := section(m, "logging")["file"]; v != nil && v != "" {
		return problem("unsupported", "首版由应用管理日志，不向配置指定的路径写入。", "logging.file")
	}
	if _, ok := m["local_api"]; ok {
		return problem("unsupported", "首版仅使用应用私有管道，不开放本地管理接口。", "local_api")
	}
	if p := section(m, "pki"); p != nil {
		for k := range p {
			if k != "ca" && k != "cert" && k != "key" && k != "blocklist" && k != "disconnect_invalid" && k != "disconnect_expired" {
				return problem("unsupported", "不支持该凭据设置。", "pki."+k)
			}
		}
	}
	return validateRuntimeBounds(m)
}
func Inspect(path, name string, files map[string]string, now time.Time) (*Candidate, error) {
	st, err := os.Stat(path)
	if err != nil {
		return nil, problem("missing_file", "无法读取配置，请重新选择文件或包含凭据的文件夹。", "config")
	}
	if st.IsDir() {
		entries, e := os.ReadDir(path)
		if e != nil {
			return nil, problem("missing_file", "无法读取文件夹。", "config")
		}
		var choices []string
		for _, x := range entries {
			if !x.IsDir() && (strings.EqualFold(filepath.Ext(x.Name()), ".yaml") || strings.EqualFold(filepath.Ext(x.Name()), ".yml")) {
				choices = append(choices, filepath.Join(path, x.Name()))
			}
		}
		if len(choices) != 1 {
			return nil, problem("ambiguous_config", "请选择唯一的 YAML 配置文件；该文件夹中没有配置或包含多个配置。", "config")
		}
		path = choices[0]
	}
	b, err := readPrivateInput(path)
	if err != nil {
		return nil, problem("missing_file", "配置必须是可读取且不超过 2 MB 的普通文件，不能是符号链接。", "config")
	}
	m, err := parseConfig(b)
	if err != nil {
		return nil, err
	}
	if err = validatePolicy(m); err != nil {
		return nil, err
	}
	pki := section(m, "pki")
	if pki == nil {
		return nil, problem("missing_file", "配置缺少身份凭据。", "pki")
	}
	for _, role := range []string{"ca", "cert", "key"} {
		value, ok := pki[role].(string)
		if !ok || strings.TrimSpace(value) == "" {
			return nil, problem("missing_file", "请选择配置引用的凭据文件。", "pki."+role)
		}
		if override := files[role]; override != "" {
			value = override
		} else if strings.Contains(value, "-----BEGIN ") {
			continue
		}
		if !filepath.IsAbs(value) {
			value = filepath.Join(filepath.Dir(path), value)
		}
		data, e := readPrivateInput(value)
		if e != nil {
			return nil, problem("missing_file", "找不到或无法读取凭据文件，请补选对应文件。", "pki."+role)
		}
		pki[role] = string(data)
	}
	ca, err := cert.NewCAPoolFromPEM([]byte(pki["ca"].(string)))
	if err != nil || len(ca.CAs) == 0 {
		return nil, problem("invalid_ca", "CA 证书无效、已过期或包含不支持的证书，请联系管理员。", "pki.ca")
	}
	host, rest, err := cert.UnmarshalCertificateFromPEM([]byte(pki["cert"].(string)))
	if err != nil || len(bytes.TrimSpace(rest)) != 0 || host.IsCA() {
		return nil, problem("invalid_certificate", "主机证书无效，或包含多个证书；此验证版每个配置支持一个主机证书。", "pki.cert")
	}
	if now.Before(host.NotBefore()) {
		return nil, problem("not_yet_valid", "主机证书尚未生效，请检查系统时间或联系管理员。", "pki.cert")
	}
	if now.After(host.NotAfter()) {
		return nil, problem("expired", "主机证书已过期，请联系管理员更新。", "pki.cert")
	}
	for _, n := range host.Networks() {
		if n.Bits() == 0 {
			return nil, problem("unsupported", "主机证书不能声明默认路由。", "pki.cert")
		}
	}
	if _, err = ca.VerifyCertificate(now, host); err != nil {
		return nil, problem("untrusted_certificate", "主机证书不受此 CA 信任、违反 CA 约束或已失效。", "pki.cert")
	}
	key, rest, curve, err := cert.UnmarshalPrivateKeyFromPEM([]byte(pki["key"].(string)))
	if err != nil || len(bytes.TrimSpace(rest)) != 0 {
		return nil, problem("invalid_key", "主机密钥格式无效或不受支持。", "pki.key")
	}
	if host.VerifyPrivateKey(curve, key) != nil {
		return nil, problem("key_mismatch", "主机证书与密钥不匹配。", "pki.key")
	}
	// Validate through the actual kernel, while discarding its config-test output.
	runtime, err := yaml.Marshal(m)
	if err != nil {
		return nil, problem("invalid_config", "无法读取配置。", "config")
	}
	c := config.NewC(logging.NewLogger(io.Discard))
	if c.LoadString(string(runtime)) != nil {
		return nil, problem("invalid_config", "内核无法解析配置。", "config")
	}
	if _, err = nebula.Main(c, true, "nebula-gui-validation", logging.NewLogger(io.Discard), nil); err != nil {
		return nil, problem("invalid_config", "Nebula 内核拒绝此配置，请检查防火墙、发现节点和网络参数。", "config")
	}
	if strings.TrimSpace(name) == "" {
		name = host.Name()
	}
	name = strings.TrimSpace(name)
	if len(name) > 160 || strings.ContainsAny(name, "\n\r\x00") {
		return nil, problem("invalid_name", "网络名称过长或包含控制字符。", "name")
	}
	fp, err := host.Fingerprint()
	if err != nil {
		return nil, problem("invalid_certificate", "无法读取证书指纹。", "pki.cert")
	}
	digest := sha256.Sum256(runtime)
	profile := Profile{Name: name, Device: host.Name(), Networks: []string{}, Groups: host.Groups(), Fingerprint: fp, ExpiresAt: host.NotAfter(), ImportedAt: now.UTC(), Digest: hex.EncodeToString(digest[:])}
	for _, n := range host.Networks() {
		profile.Networks = append(profile.Networks, n.String())
	}
	if len(profile.Networks) == 0 {
		return nil, problem("invalid_certificate", "证书没有 Nebula 地址。", "pki.cert")
	}
	return &Candidate{Profile: profile, Config: runtime}, nil
}

// These bounds precede config-test, which also allocates handshake channels.
func validateRuntimeBounds(m map[string]any) error {
	limits := map[string][2]int{
		"routines": {0, 16}, "tun.routines": {1, 16}, "listen.routines": {1, 16},
		"lighthouse.interval": {0, 86400},
		"tun.tx_queue":        {0, 65536}, "listen.batch": {0, 256},
		"listen.read_buffer": {0, 16 << 20}, "listen.write_buffer": {0, 16 << 20},
		"handshakes.trigger_buffer": {0, 16384}, "handshakes.query_buffer": {0, 16384}, "handshakes.retries": {0, 32},
	}
	for path, bounds := range limits {
		parts := strings.Split(path, ".")
		var value any
		if len(parts) == 1 {
			value = m[parts[0]]
		} else {
			value = section(m, parts[0])[parts[1]]
		}
		if value == nil {
			continue
		}
		n, ok := value.(int)
		if !ok || n < bounds[0] || n > bounds[1] {
			return problem("unsupported", "运行参数超出安全范围。", path)
		}
	}
	if _, err := boundedRuntimeDuration(section(m, "handshakes")["try_interval"], "handshakes.try_interval", 100*time.Millisecond, 10*time.Millisecond, time.Minute, false); err != nil {
		return err
	}
	conntrack := section(section(m, "firewall"), "conntrack")
	if _, err := boundedRuntimeDuration(conntrack["routine_cache_timeout"], "firewall.conntrack.routine_cache_timeout", 0, 10*time.Millisecond, 24*time.Hour, true); err != nil {
		return err
	}
	// Match defaults in the pinned kernel, and include omitted timeouts when
	// bounding the wheel: it allocates max/min+2 slots even in config-test.
	var minimum, maximum time.Duration
	for key, fallback := range map[string]time.Duration{"tcp_timeout": 12 * time.Minute, "udp_timeout": 3 * time.Minute, "default_timeout": 10 * time.Minute} {
		d, err := boundedRuntimeDuration(conntrack[key], "firewall.conntrack."+key, fallback, time.Millisecond, 24*time.Hour, false)
		if err != nil {
			return err
		}
		if minimum == 0 || d < minimum {
			minimum = d
		}
		if d > maximum {
			maximum = d
		}
	}
	if maximum/minimum+2 > 65536 {
		return problem("unsupported", "连接跟踪超时参数需要过多计时槽位。", "firewall.conntrack")
	}
	return nil
}

func boundedRuntimeDuration(value any, field string, fallback, minimum, maximum time.Duration, allowZero bool) (time.Duration, error) {
	if value == nil {
		return fallback, nil
	}
	text, ok := value.(string)
	d, err := time.ParseDuration(text)
	if !ok || err != nil || (d == 0 && !allowZero) || (d != 0 && (d < minimum || d > maximum)) {
		return 0, problem("unsupported", "计时参数超出安全范围。", field)
	}
	return d, nil
}
