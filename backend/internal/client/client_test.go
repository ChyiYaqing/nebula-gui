package client

import (
	"bufio"
	"bytes"
	"crypto/ecdh"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/slackhq/nebula/cert"
	"go.yaml.in/yaml/v3"
)

func fixtureAt(t *testing.T, dir string, expires time.Time) string {
	t.Helper()
	now := time.Now()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ca, err := (&cert.TBSCertificate{Version: cert.Version2, Name: "Temporary Test CA", IsCA: true, Curve: cert.Curve_CURVE25519, NotBefore: now.Add(-48 * time.Hour), NotAfter: now.Add(72 * time.Hour), PublicKey: pub}).Sign(nil, cert.Curve_CURVE25519, priv)
	if err != nil {
		t.Fatal(err)
	}
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	host, err := (&cert.TBSCertificate{Version: cert.Version2, Name: "test-mac", Curve: cert.Curve_CURVE25519, NotBefore: now.Add(-24 * time.Hour), NotAfter: expires, PublicKey: key.PublicKey().Bytes(), Networks: mustPrefixes("10.73.0.2/24")}).Sign(ca, cert.Curve_CURVE25519, priv)
	if err != nil {
		t.Fatal(err)
	}
	caPEM, _ := ca.MarshalPEM()
	hostPEM, _ := host.MarshalPEM()
	if err = os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string][]byte{"ca.cert": caPEM, "host.cert": hostPEM, "host.key": cert.MarshalPrivateKeyToPEM(cert.Curve_CURVE25519, key.Bytes())} {
		if err = os.WriteFile(filepath.Join(dir, name), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	body := `pki:
  ca: ca.cert
  cert: host.cert
  key: host.key
static_host_map:
  '10.73.0.1': ['127.0.0.1:4242']
lighthouse:
  hosts: ['10.73.0.1']
listen:
  host: 127.0.0.1
  port: 0
tun:
  dev: ''
firewall:
  outbound:
    - port: any
      proto: any
      host: any
  inbound:
    - port: any
      proto: icmp
      host: any
`
	path := filepath.Join(dir, "config.yaml")
	if err = os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	return path
}
func fixture(t *testing.T) string { return fixtureAt(t, t.TempDir(), time.Now().Add(24*time.Hour)) }
func openStore(t *testing.T) *Store {
	t.Helper()
	s, e := NewStore(filepath.Join(t.TempDir(), "store"))
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(s.Close)
	return s
}
func code(t *testing.T, err error, want string) {
	t.Helper()
	var p *Problem
	if !errors.As(err, &p) || p.Code != want {
		t.Fatalf("wanted %s; got %v", want, err)
	}
}
func changeYAML(t *testing.T, path string, change func(map[string]any)) {
	t.Helper()
	b, e := os.ReadFile(path)
	if e != nil {
		t.Fatal(e)
	}
	var m map[string]any
	if e = yaml.Unmarshal(b, &m); e != nil {
		t.Fatal(e)
	}
	change(m)
	b, e = yaml.Marshal(m)
	if e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(path, b, 0600); e != nil {
		t.Fatal(e)
	}
}
func TestImportAndIndependentCopy(t *testing.T) {
	path := fixture(t)
	original, _ := os.ReadFile(path)
	c, e := Inspect(path, "My Network", nil, time.Now())
	if e != nil {
		t.Fatal(e)
	}
	if c.Profile.Device != "test-mac" || c.Profile.Networks[0] != "10.73.0.2/24" {
		t.Fatal("wrong identity")
	}
	store := openStore(t)
	p, e := store.Save(c, "")
	if e != nil {
		t.Fatal(e)
	}
	after, _ := os.ReadFile(path)
	if !bytes.Equal(original, after) {
		t.Fatal("source modified")
	}
	if e = os.RemoveAll(filepath.Dir(path)); e != nil {
		t.Fatal(e)
	}
	loaded, b, e := store.Load(p.ID)
	if e != nil || loaded.Digest != p.Digest {
		t.Fatal("copy unavailable")
	}
	runtime := filepath.Join(t.TempDir(), "config.yaml")
	_ = os.WriteFile(runtime, b, 0600)
	if _, e = Inspect(runtime, "", nil, time.Now()); e != nil {
		t.Fatal(e)
	}
	dir, _ := store.versionDir(p.ID, p.Version)
	info, _ := os.Stat(filepath.Join(dir, "config.yaml"))
	if info.Mode().Perm() != 0600 {
		t.Fatal("private config permissions")
	}
}
func TestCredentialFailures(t *testing.T) {
	t.Run("missing and supplement", func(t *testing.T) {
		path := fixture(t)
		other := filepath.Join(t.TempDir(), "renamed.key")
		_ = os.Rename(filepath.Join(filepath.Dir(path), "host.key"), other)
		_, e := Inspect(path, "", nil, time.Now())
		code(t, e, "missing_file")
		if _, e = Inspect(path, "", map[string]string{"key": other}, time.Now()); e != nil {
			t.Fatal(e)
		}
	})
	t.Run("mismatch", func(t *testing.T) {
		path := fixture(t)
		other := fixture(t)
		key, _ := os.ReadFile(filepath.Join(filepath.Dir(other), "host.key"))
		_ = os.WriteFile(filepath.Join(filepath.Dir(path), "host.key"), key, 0600)
		_, e := Inspect(path, "", nil, time.Now())
		code(t, e, "key_mismatch")
	})
	t.Run("expired", func(t *testing.T) {
		path := fixtureAt(t, t.TempDir(), time.Now().Add(-time.Hour))
		_, e := Inspect(path, "", nil, time.Now())
		code(t, e, "expired")
	})
	t.Run("untrusted", func(t *testing.T) {
		path := fixture(t)
		other := fixture(t)
		ca, _ := os.ReadFile(filepath.Join(filepath.Dir(other), "ca.cert"))
		_ = os.WriteFile(filepath.Join(filepath.Dir(path), "ca.cert"), ca, 0600)
		_, e := Inspect(path, "", nil, time.Now())
		code(t, e, "untrusted_certificate")
	})
	t.Run("symlink", func(t *testing.T) {
		path := fixture(t)
		link := filepath.Join(t.TempDir(), "link.yaml")
		_ = os.Symlink(path, link)
		_, e := Inspect(link, "", nil, time.Now())
		code(t, e, "missing_file")
	})
}
func TestPolicyRejectsUnsupportedSettings(t *testing.T) {
	for _, tc := range []struct {
		name string
		edit func(map[string]any)
	}{
		{"gateway", func(m map[string]any) {
			section(m, "tun")["unsafe_routes"] = []any{map[string]any{"route": "0.0.0.0/0", "via": "10.73.0.1"}}
		}},
		{"DNS", func(m map[string]any) { m["dns"] = map[string]any{"enabled": true} }},
		{"lighthouse", func(m map[string]any) { section(m, "lighthouse")["am_lighthouse"] = true }},
		{"relay server", func(m map[string]any) { m["relay"] = map[string]any{"am_relay": true} }},
		{"management socket", func(m map[string]any) { m["local_api"] = map[string]any{} }},
		{"unknown setting", func(m map[string]any) { m["arbitrary"] = true }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := fixture(t)
			changeYAML(t, path, tc.edit)
			_, e := Inspect(path, "", nil, time.Now())
			code(t, e, "unsupported")
		})
	}
	t.Run("client relay allowed", func(t *testing.T) {
		path := fixture(t)
		changeYAML(t, path, func(m map[string]any) { m["relay"] = map[string]any{"use_relays": true, "relays": []any{"10.73.0.1"}} })
		if _, e := Inspect(path, "", nil, time.Now()); e != nil {
			t.Fatal(e)
		}
	})
}
func TestYAMLAndSelectionLimits(t *testing.T) {
	for _, text := range []string{"x: 1\nx: 2", "pki: 1\n---\npki: 2", "x: &x [1, 2]\ny: *x", "[1,2]"} {
		if _, e := parseConfig([]byte(text)); e == nil {
			t.Fatal("accepted invalid YAML")
		}
	}
	path := fixture(t)
	_ = os.WriteFile(filepath.Join(filepath.Dir(path), "other.yml"), []byte("pki: {}"), 0600)
	_, e := Inspect(filepath.Dir(path), "", nil, time.Now())
	code(t, e, "ambiguous_config")
	large := filepath.Join(t.TempDir(), "big.yaml")
	_ = os.WriteFile(large, bytes.Repeat([]byte("x"), maxFileSize+1), 0600)
	_, e = Inspect(large, "", nil, time.Now())
	code(t, e, "missing_file")
}

type fakeEngine struct {
	starts, stops int
	alive         bool
	fail          bool
}

func (e *fakeEngine) Start([]byte) error {
	e.starts++
	if e.fail {
		return problem("authorization_required", "permission denied", "")
	}
	e.alive = true
	return nil
}
func (e *fakeEngine) Stop()         { e.stops++; e.alive = false }
func (e *fakeEngine) Alive() bool   { return e.alive }
func (e *fakeEngine) Peers() []Peer { return []Peer{} }
func request(s *Service, method, id string) Response {
	return s.Handle(Request{Version: 1, ID: "test", Method: method, ProfileID: id})
}
func TestLifecycleAndUpdateRollback(t *testing.T) {
	store := openStore(t)
	candidate, e := Inspect(fixture(t), "First", nil, time.Now())
	if e != nil {
		t.Fatal(e)
	}
	first, e := store.Save(candidate, "")
	if e != nil {
		t.Fatal(e)
	}
	engine := &fakeEngine{}
	s := NewService(store, engine)
	defer s.Close()
	if r := request(s, "connect", first.ID); r.Error != nil {
		t.Fatal(r.Error)
	}
	if r := request(s, "connect", first.ID); r.Error != nil || engine.starts != 1 {
		t.Fatal("non-idempotent connect")
	}
	if r := request(s, "remove", first.ID); r.Error == nil || r.Error.Code != "active_profile" {
		t.Fatal("removed active profile")
	}
	if r := request(s, "disconnect", ""); r.Error != nil || engine.alive {
		t.Fatal("failed disconnect")
	}
	candidate.Profile.Name = "Second"
	second, e := store.Save(candidate, first.ID)
	if e != nil || second.Version == first.Version {
		t.Fatal("update failed")
	}
	restored, e := store.Rollback(first.ID)
	if e != nil || restored.Version != first.Version {
		t.Fatal("rollback failed")
	}
	engine.fail = true
	if r := request(s, "connect", first.ID); r.Error == nil || r.Error.Code != "authorization_required" {
		t.Fatal("missing permission error")
	}
	if s.status().State != "failed" || engine.alive {
		t.Fatal("false started state")
	}
	request(s, "disconnect", "")
	if s.status().State != "disconnected" {
		t.Fatal("failed state not cleared")
	}
}
func TestChangedSourceAndInvalidIDs(t *testing.T) {
	store := openStore(t)
	engine := &fakeEngine{}
	s := NewService(store, engine)
	defer s.Close()
	path := fixture(t)
	c, e := Inspect(path, "", nil, time.Now())
	if e != nil {
		t.Fatal(e)
	}
	changeYAML(t, path, func(m map[string]any) { m["punchy"] = map[string]any{"punch": true} })
	r := s.Handle(Request{Version: 1, ID: "test", Method: "import", Path: path, Digest: c.Profile.Digest})
	if r.Error == nil || r.Error.Code != "source_changed" {
		t.Fatal("accepted changed source")
	}
	list, _ := store.List()
	if len(list) != 0 {
		t.Fatal("partial import")
	}
	for _, id := range []string{"../escape", "", strings.Repeat("a", 33)} {
		_, _, e = store.Load(id)
		code(t, e, "invalid_id")
	}
}
func TestStoreLockAndPermissions(t *testing.T) {
	s := openStore(t)
	if other, e := NewStore(s.root); e == nil {
		other.Close()
		t.Fatal("multiple writers")
	}
	public := filepath.Join(t.TempDir(), "public")
	_ = os.Mkdir(public, 0755)
	if x, e := NewStore(public); e == nil {
		x.Close()
		t.Fatal("unsafe store")
	}
	link := filepath.Join(t.TempDir(), "link")
	_ = os.Symlink(s.root, link)
	if x, e := NewStore(link); e == nil {
		x.Close()
		t.Fatal("symlink store")
	}
}
func TestProtocolAndDiagnosticRedaction(t *testing.T) {
	for _, payload := range []string{`{"version":1,"id":"x","method":"status","shell":"cat secret"}`, `[]`, `null`, `{"version":"bad"}`} {
		if _, e := DecodeRequest([]byte(payload)); e == nil {
			t.Fatal("invalid request accepted")
		}
	}
	s := NewService(openStore(t), &fakeEngine{})
	defer s.Close()
	if r := s.Handle(Request{Version: 99, ID: "x", Method: "list"}); r.Error == nil || r.Error.Code != "protocol_mismatch" {
		t.Fatal("protocol version ignored")
	}
	candidate, e := Inspect(fixture(t), "PRIVATE DEVICE NAME", nil, time.Now())
	if e != nil {
		t.Fatal(e)
	}
	_, _ = s.store.Save(candidate, "")
	r := request(s, "diagnostics", "")
	b, _ := json.Marshal(r)
	for _, secret := range []string{"PRIVATE DEVICE NAME", "test-mac", "10.73.0.2", "BEGIN", "ca.cert", s.store.root} {
		if bytes.Contains(b, []byte(secret)) {
			t.Fatalf("diagnostic leaked %s", secret)
		}
	}
}
func TestStdioIntegration(t *testing.T) {
	binary := os.Getenv("NEBULA_GUI_TEST_BACKEND")
	if binary == "" {
		t.Skip("set NEBULA_GUI_TEST_BACKEND to built backend")
	}
	cmd := exec.Command(binary, "serve", "--store", filepath.Join(t.TempDir(), "store"))
	in, _ := cmd.StdinPipe()
	out, _ := cmd.StdoutPipe()
	if e := cmd.Start(); e != nil {
		t.Fatal(e)
	}
	scanner := bufio.NewScanner(out)
	scanner.Buffer(make([]byte, 4096), maxFileSize)
	send := func(r Request) Response {
		t.Helper()
		b, _ := json.Marshal(r)
		_, _ = in.Write(append(b, '\n'))
		if !scanner.Scan() {
			t.Fatal("no backend response")
		}
		var reply Response
		if e := json.Unmarshal(scanner.Bytes(), &reply); e != nil {
			t.Fatal(e)
		}
		if reply.ID != r.ID {
			t.Fatal("response ID mismatch")
		}
		return reply
	}
	path := fixture(t)
	preview := send(Request{Version: 1, ID: "1", Method: "preview", Path: path})
	if preview.Error != nil {
		t.Fatal(preview.Error)
	}
	data, _ := json.Marshal(preview.Result)
	var p Profile
	_ = json.Unmarshal(data, &p)
	saved := send(Request{Version: 1, ID: "2", Method: "import", Path: path, Digest: p.Digest})
	if saved.Error != nil {
		t.Fatal(saved.Error)
	}
	if r := send(Request{Version: 1, ID: "3", Method: "list"}); r.Error != nil {
		t.Fatal(r.Error)
	}
	_ = in.Close()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case e := <-done:
		if e != nil {
			t.Fatal(e)
		}
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("backend did not exit on EOF")
	}
}
func TestNativeConnectionAttempt(t *testing.T) {
	if os.Getenv("NEBULA_GUI_NATIVE_TEST") != "1" {
		t.Skip("explicitly enable native networking test")
	}
	candidate, e := Inspect(fixture(t), "", nil, time.Now())
	if e != nil {
		t.Fatal(e)
	}
	engine := &NativeEngine{}
	defer engine.Stop()
	e = engine.Start(candidate.Config)
	if e != nil {
		var p *Problem
		if !errors.As(e, &p) {
			t.Fatal("raw native error")
		}
		t.Logf("native start result: %s (no simulated connection)", p.Code)
		if engine.Alive() {
			t.Fatal("failed native engine reported started")
		}
		return
	}
	if !engine.Alive() {
		t.Fatal("native engine did not start")
	}
	engine.Stop()
	if engine.Alive() {
		t.Fatal("native engine did not stop")
	}
}
func TestExportDevelopmentFixture(t *testing.T) {
	dir := os.Getenv("NEBULA_GUI_FIXTURE_DIR")
	if dir == "" {
		t.Skip("optional temporary GUI fixture export")
	}
	fixtureAt(t, dir, time.Now().Add(24*time.Hour))
}

func mustPrefixes(values ...string) []netip.Prefix {
	out := []netip.Prefix{}
	for _, v := range values {
		out = append(out, netip.MustParsePrefix(v))
	}
	return out
}

func TestPrivateDirectoryOwnerCheck(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := checkPrivateDirectory(dir, uint32(os.Geteuid())); err != nil {
		t.Fatal(err)
	}
	if err := checkPrivateDirectory(dir, uint32(os.Geteuid())+1); err == nil {
		t.Fatal("accepted another owner's private directory")
	}
}
