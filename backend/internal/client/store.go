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
	"time"

	"golang.org/x/sys/unix"
)

var safeID = regexp.MustCompile(`^[a-f0-9]{32}$`)

type pointer struct {
	Version  string `json:"version"`
	Previous string `json:"previous,omitempty"`
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
		return nil, errors.New("store requires a private 0700 directory")
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
		return nil, errors.New("another backend owns this store")
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
	return os.Rename(f.Name(), path)
}
func (s *Store) Save(c *Candidate, replace string) (Profile, error) {
	p := c.Profile
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
	if err := os.WriteFile(filepath.Join(dir, "config.yaml"), c.Config, 0600); err != nil {
		return Profile{}, err
	}
	if err := atomicJSON(filepath.Join(dir, "profile.json"), p); err != nil {
		return Profile{}, err
	}
	if err := atomicJSON(filepath.Join(s.root, "profiles", p.ID+".json"), pointer{p.Version, previous}); err != nil {
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
	if e = atomicJSON(filepath.Join(s.root, "profiles", id+".json"), pointer{p.Previous, p.Version}); e != nil {
		return Profile{}, e
	}
	profile, _, e := s.Load(id)
	return profile, e
}
func (s *Store) Remove(id string) error {
	if _, e := s.index(id); e != nil {
		return e
	}
	// First unpublish the profile; all removal paths are constructed from a validated ID.
	if e := os.Remove(filepath.Join(s.root, "profiles", id+".json")); e != nil {
		return e
	}
	return os.RemoveAll(filepath.Join(s.root, "profiles", id))
}
