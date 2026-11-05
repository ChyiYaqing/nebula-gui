package client

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// Cleanup only knows the current file-based schema. Unknown entries are retained.
func privateDirAt(parent int, name string) (*os.File, error) {
	fd, err := unix.Openat(parent, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), "managed directory")
	var st unix.Stat_t
	if err = unix.Fstat(fd, &st); err != nil || st.Uid != uint32(os.Geteuid()) || st.Mode&0077 != 0 {
		f.Close()
		return nil, errors.New("unsafe cleanup directory")
	}
	return f, nil
}

func removeManagedVersion(base *os.File, version string) error {
	if !safeID.MatchString(version) {
		return errors.New("invalid cleanup version")
	}
	dir, err := privateDirAt(int(base.Fd()), version)
	if err != nil {
		return err
	}
	defer dir.Close()
	entries, err := dir.ReadDir(-1)
	if err != nil {
		return err
	}
	// Preflight the whole version before unlinking any file. Never recurse or follow links.
	for _, entry := range entries {
		if entry.Name() != "config.yaml" && entry.Name() != "profile.json" && !writeTemporary(entry.Name()) {
			return errors.New("unknown version entry")
		}
		var st unix.Stat_t
		if unix.Fstatat(int(dir.Fd()), entry.Name(), &st, unix.AT_SYMLINK_NOFOLLOW) != nil || st.Mode&unix.S_IFMT != unix.S_IFREG || st.Mode&0077 != 0 || st.Uid != uint32(os.Geteuid()) || st.Nlink != 1 {
			return errors.New("unsafe version file")
		}
	}
	for _, entry := range entries {
		if err = unix.Unlinkat(int(dir.Fd()), entry.Name(), 0); err != nil {
			return err
		}
	}
	var opened, named unix.Stat_t
	if unix.Fstat(int(dir.Fd()), &opened) != nil || unix.Fstatat(int(base.Fd()), version, &named, unix.AT_SYMLINK_NOFOLLOW) != nil || opened.Dev != named.Dev || opened.Ino != named.Ino {
		return errors.New("cleanup directory changed")
	}
	return unix.Unlinkat(int(base.Fd()), version, unix.AT_REMOVEDIR)
}

func writeTemporary(name string) bool {
	suffix := strings.TrimPrefix(name, ".write-")
	if suffix == name || suffix == "" {
		return false
	}
	for _, c := range suffix {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func (s *Store) pruneProfile(id string, removed bool) error {
	if !safeID.MatchString(id) {
		return errors.New("invalid cleanup profile")
	}
	keep := map[string]bool{}
	if !removed {
		index, err := s.index(id)
		if err != nil {
			return err
		}
		if _, _, err = s.Load(id); err != nil {
			return err
		}
		keep[index.Version] = true
		if index.Previous != "" {
			dir, err := s.versionDir(id, index.Previous)
			if err != nil {
				return err
			}
			summary, err := readPrivateInput(filepath.Join(dir, "profile.json"))
			if err != nil {
				return err
			}
			var previous Profile
			if json.Unmarshal(summary, &previous) != nil || previous.ID != id || previous.Version != index.Previous {
				return errors.New("invalid previous summary")
			}
			if _, err = readPrivateInput(filepath.Join(dir, "config.yaml")); err != nil {
				return err
			}
			keep[index.Previous] = true
		}
	}
	root, err := privateDirAt(unix.AT_FDCWD, s.root)
	if err != nil {
		return err
	}
	defer root.Close()
	profiles, err := privateDirAt(int(root.Fd()), "profiles")
	if err != nil {
		return err
	}
	defer profiles.Close()
	base, err := privateDirAt(int(profiles.Fd()), id)
	if removed && os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	defer base.Close()
	entries, err := base.ReadDir(-1)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		if !safeID.MatchString(entry.Name()) {
			return errors.New("unknown profile entry")
		}
		if keep[entry.Name()] {
			continue
		}
		if err = removeManagedVersion(base, entry.Name()); err != nil {
			return err
		}
	}
	if removed {
		var opened, named unix.Stat_t
		if unix.Fstat(int(base.Fd()), &opened) != nil || unix.Fstatat(int(profiles.Fd()), id, &named, unix.AT_SYMLINK_NOFOLLOW) != nil || opened.Dev != named.Dev || opened.Ino != named.Ino {
			return errors.New("removed profile changed")
		}
		return unix.Unlinkat(int(profiles.Fd()), id, unix.AT_REMOVEDIR)
	}
	return nil
}

// Prune is called by the serial service loop. The active profile is entirely
// protected, including when tunnel cleanup has not yet been confirmed.
func (s *Store) Prune(protectedID string) error {
	entries, err := os.ReadDir(filepath.Join(s.root, "profiles"))
	if err != nil {
		return err
	}
	var failures []error
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasSuffix(name, ".json") {
			id := strings.TrimSuffix(name, ".json")
			if safeID.MatchString(id) && id != protectedID {
				if err := s.pruneProfile(id, false); err != nil {
					failures = append(failures, err)
				}
			}
		} else if strings.HasSuffix(name, ".removed") {
			id := strings.TrimSuffix(name, ".removed")
			if !safeID.MatchString(id) || id == protectedID {
				continue
			}
			// A tombstone is a private, recoverable marker written by Remove, never a
			// guess that an unindexed directory is disposable.
			marker, err := readPrivateInput(filepath.Join(s.root, "profiles", name))
			if err != nil {
				failures = append(failures, err)
				continue
			}
			var index pointer
			if json.Unmarshal(marker, &index) != nil || !safeID.MatchString(index.Version) || (index.Previous != "" && !safeID.MatchString(index.Previous)) {
				failures = append(failures, errors.New("invalid removal marker"))
				continue
			}
			if _, err := os.Lstat(filepath.Join(s.root, "profiles", id+".json")); !os.IsNotExist(err) {
				failures = append(failures, errors.New("live removal marker"))
				continue
			}
			if err := s.pruneProfile(id, true); err != nil {
				failures = append(failures, err)
				continue
			}
			if err := os.Remove(filepath.Join(s.root, "profiles", name)); err != nil {
				failures = append(failures, err)
			}
		}
	}
	return errors.Join(failures...)
}
