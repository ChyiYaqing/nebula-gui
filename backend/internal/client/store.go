package client

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"golang.org/x/sys/unix"
)

var safeID = regexp.MustCompile(`^[a-f0-9]{32}$`)

// Store open failures the backend reports to the GUI as structured problems (#84).
var (
	ErrStoreInUse      = errors.New("another backend owns this store")
	ErrStoreNotPrivate = errors.New("store requires a private 0700 directory")
)

type pointer struct {
	Version     string `json:"version"`
	Previous    string `json:"previous,omitempty"`
	DisplayName string `json:"displayName,omitempty"`
}
type Store struct {
	root string
	lock *os.File
}

func newID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	return hex.EncodeToString(b[:])
}
func NewStore(root string) (*Store, error) {
	if !filepath.IsAbs(root) {
		return nil, errors.New("store path must be absolute")
	}
	if err := os.MkdirAll(root, 0700); err != nil {
		return nil, err
	}
	st, err := os.Lstat(root)
	if err != nil || !st.IsDir() || st.Mode().Perm()&0077 != 0 {
		return nil, ErrStoreNotPrivate
	}
	// Resolve parent aliases such as macOS /var -> /private/var, but never
	// follow a symlink used as the managed directory itself (checked above).
	parent, err := filepath.EvalSymlinks(filepath.Dir(root))
	if err != nil {
		return nil, err
	}
	root = filepath.Join(parent, filepath.Base(root))
	if err := checkPrivateDirectory(root, uint32(os.Geteuid())); err != nil {
		return nil, err
	}
	fd, err := unix.Open(filepath.Join(root, ".lock"), unix.O_CREAT|unix.O_RDWR|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0600)
	if err != nil {
		return nil, err
	}
	lock := os.NewFile(uintptr(fd), "store lock")
	if err = unix.Flock(fd, unix.LOCK_EX|unix.LOCK_NB); err != nil {
		lock.Close()
		return nil, ErrStoreInUse
	}
	if err = os.MkdirAll(filepath.Join(root, "profiles"), 0700); err != nil {
		lock.Close()
		return nil, err
	}
	s := &Store{root: root, lock: lock}
	if err = s.checkDir(filepath.Join(root, "profiles")); err != nil {
		lock.Close()
		return nil, err
	}
	return s, nil
}
func (s *Store) Close() {
	if s.lock != nil {
		s.lock.Close()
		s.lock = nil
	}
}
func checkPrivateDirectory(path string, expectedUID uint32) error {
	var st unix.Stat_t
	if unix.Lstat(path, &st) != nil || st.Mode&unix.S_IFMT != unix.S_IFDIR || st.Mode&0077 != 0 || st.Uid != expectedUID {
		return errors.New("unsafe store directory or owner")
	}
	return nil
}
func (s *Store) checkDir(path string) error { return checkPrivateDirectory(path, uint32(os.Geteuid())) }
func (s *Store) index(id string) (pointer, error) {
	var p pointer
	if !safeID.MatchString(id) {
		return p, problem("invalid_id", "配置标识无效。", "profileID")
	}
	b, e := readPrivateInput(filepath.Join(s.root, "profiles", id+".json"))
	if e != nil {
		return p, problem("not_found", "找不到该配置。", "profileID")
	}
	if json.Unmarshal(b, &p) != nil || !safeID.MatchString(p.Version) || (p.Previous != "" && !safeID.MatchString(p.Previous)) {
		return p, problem("corrupt_store", "配置索引损坏。", "profileID")
	}
	return p, nil
}
func (s *Store) versionDir(id, version string) (string, error) {
	if !safeID.MatchString(id) || !safeID.MatchString(version) {
		return "", problem("invalid_id", "配置标识无效。", "profileID")
	}
	base := filepath.Join(s.root, "profiles", id)
	path := filepath.Join(base, version)
	if s.checkDir(base) != nil || s.checkDir(path) != nil {
		return "", problem("corrupt_store", "配置目录不可用。", "profileID")
	}
	return path, nil
}
func (s *Store) Load(id string) (Profile, []byte, error) {
	p, e := s.index(id)
	if e != nil {
		return Profile{}, nil, e
	}
	dir, e := s.versionDir(id, p.Version)
	if e != nil {
		return Profile{}, nil, e
	}
	b, e := readPrivateInput(filepath.Join(dir, "profile.json"))
	if e != nil {
		return Profile{}, nil, problem("corrupt_store", "配置摘要不可用。", "profileID")
	}
	var profile Profile
	if json.Unmarshal(b, &profile) != nil || profile.ID != id || profile.Version != p.Version {
		return Profile{}, nil, problem("corrupt_store", "配置摘要损坏。", "profileID")
	}
	if p.DisplayName != "" {
		name, err := normalizedProfileName(p.DisplayName)
		if err != nil {
			return Profile{}, nil, problem("corrupt_store", "网络显示名称损坏。", "name")
		}
		profile.Name = name
	}
	config, e := readPrivateInput(filepath.Join(dir, "config.yaml"))
	if e != nil {
		return Profile{}, nil, problem("corrupt_store", "受管配置不可用。", "profileID")
	}
	return profile, config, nil
}
func (s *Store) List() ([]Profile, error) {
	entries, e := os.ReadDir(filepath.Join(s.root, "profiles"))
	if e != nil {
		return nil, e
	}
	profiles := []Profile{}
	for _, x := range entries {
		if filepath.Ext(x.Name()) != ".json" {
			continue
		}
		id := x.Name()[:len(x.Name())-5]
		if !safeID.MatchString(id) {
			continue
		}
		p, _, err := s.Load(id)
		if err != nil {
			return nil, err
		}
		profiles = append(profiles, p)
	}
	sort.Slice(profiles, func(i, j int) bool { return profiles[i].ImportedAt.Before(profiles[j].ImportedAt) })
	return profiles, nil
}
func atomicJSON(path string, v any) error {
	b, e := json.Marshal(v)
	if e != nil {
		return e
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".write-")
	if e != nil {
		return e
	}
	defer os.Remove(f.Name())
	if _, e = f.Write(b); e != nil {
		f.Close()
		return e
	}
	if e = f.Sync(); e != nil {
		f.Close()
		return e
	}
	if e = f.Close(); e != nil {
		return e
	}
	if e = os.Rename(f.Name(), path); e != nil {
		return e
	}
	return syncDirectory(filepath.Dir(path))
}

// syncDirectory makes new entries and renames in dir durable before a later step
// depends on them, such as publishing an index or pruning an older version.
func syncDirectory(dir string) error {
	f, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}

func writeSynced(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|unix.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
func (s *Store) Save(c *Candidate, replace string) (Profile, error) {
	p := c.Profile
	name, err := normalizedProfileName(p.Name)
	if err != nil {
		return Profile{}, err
	}
	p.Name = name
	var previous string
	if replace != "" {
		old, _, err := s.Load(replace)
		if err != nil {
			return Profile{}, err
		}
		if old.Device != p.Device || !sameNetworks(old.Networks, p.Networks) {
			return Profile{}, problem("identity_changed", "设备名或 Nebula 地址发生变化，请作为新配置导入。", "profileID")
		}
		p.ID = replace
		previous = old.Version
	} else {
		p.ID = newID()
	}
	p.Version = newID()
	base := filepath.Join(s.root, "profiles", p.ID)
	if err := os.MkdirAll(base, 0700); err != nil {
		return Profile{}, err
	}
	if s.checkDir(base) != nil {
		return Profile{}, problem("corrupt_store", "配置目录权限不安全。", "profileID")
	}
	dir := filepath.Join(base, p.Version)
	if err := os.Mkdir(dir, 0700); err != nil {
		return Profile{}, err
	}
	committed := false
	defer func() {
		if !committed {
			os.RemoveAll(dir)
		}
	}()
	if err := writeSynced(filepath.Join(dir, "config.yaml"), c.Config); err != nil {
		return Profile{}, err
	}
	if err := atomicJSON(filepath.Join(dir, "profile.json"), p); err != nil {
		return Profile{}, err
	}
	// The version directory must be durable before the index can point at it.
	if err := syncDirectory(base); err != nil {
		return Profile{}, err
	}
	if err := atomicJSON(filepath.Join(s.root, "profiles", p.ID+".json"), pointer{Version: p.Version, Previous: previous, DisplayName: p.Name}); err != nil {
		return Profile{}, err
	}
	committed = true
	return p, nil
}
func sameNetworks(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
func (s *Store) Rollback(id string) (Profile, error) {
	p, e := s.index(id)
	if e != nil {
		return Profile{}, e
	}
	if p.Previous == "" {
		return Profile{}, problem("no_previous_version", "没有可恢复的旧版本。", "profileID")
	}
	dir, e := s.versionDir(id, p.Previous)
	if e != nil {
		return Profile{}, e
	}
	if _, e = Inspect(filepath.Join(dir, "config.yaml"), "", nil, time.Now()); e != nil {
		return Profile{}, e
	}
	if e = atomicJSON(filepath.Join(s.root, "profiles", id+".json"), pointer{Version: p.Previous, Previous: p.Version, DisplayName: p.DisplayName}); e != nil {
		return Profile{}, e
	}
	profile, _, e := s.Load(id)
	return profile, e
}
func (s *Store) Remove(id string) error {
	if _, e := s.index(id); e != nil {
		return e
	}
	// Keep a recoverable removal marker so a crash or failed unlink can be retried.
	marker := filepath.Join(s.root, "profiles", id+".removed")
	if _, err := os.Lstat(marker); !os.IsNotExist(err) {
		return errors.New("removal marker already exists")
	}
	if err := os.Rename(filepath.Join(s.root, "profiles", id+".json"), marker); err != nil {
		return err
	}
	pending := problem("profile_cleanup_pending", "\u914d\u7f6e\u5df2\u79fb\u9664\uff0c\u4f46\u53d7\u7ba1\u526f\u672c\u6e05\u7406\u5c1a\u672a\u5b8c\u6210\uff1b\u5237\u65b0\u65f6\u5c06\u91cd\u8bd5\u3002", "")
	// Files are deleted only after the marker is durable; otherwise a crash could
	// restore an index that points at removed versions. Refresh retries the cleanup.
	if err := syncDirectory(filepath.Join(s.root, "profiles")); err != nil {
		return pending
	}
	if err := s.pruneProfile(id, true); err != nil {
		return pending
	}
	if err := os.Remove(marker); err != nil {
		return pending
	}
	return nil
}

func normalizedProfileName(raw string) (string, error) {
	name := strings.TrimSpace(raw)
	if !utf8.ValidString(name) || name == "" || len(name) > 160 || strings.IndexFunc(name, unicode.IsControl) >= 0 {
		return "", problem("invalid_name", "请输入简短的网络名称，不要包含换行或控制字符。", "name")
	}
	return name, nil
}

// A display name belongs to the profile, not its credential/config version.
// Changing it never rewrites credentials or consumes the rollback slot.
func (s *Store) Rename(id, rawName string) (Profile, error) {
	name, err := normalizedProfileName(rawName)
	if err != nil {
		return Profile{}, err
	}
	profile, _, err := s.Load(id)
	if err != nil {
		return Profile{}, err
	}
	if profile.Name == name {
		return profile, nil
	}
	index, err := s.index(id)
	if err != nil {
		return Profile{}, err
	}
	index.DisplayName = name
	if err = atomicJSON(filepath.Join(s.root, "profiles", id+".json"), index); err != nil {
		return Profile{}, err
	}
	profile.Name = name
	return profile, nil
}
