// Package store persists history, seen-state and version reports as JSON files.
package store

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/alessandro823/pullwatch/server/internal/history"
	"github.com/alessandro823/pullwatch/server/internal/seen"
	"github.com/alessandro823/pullwatch/server/internal/version"
)

// Store is a directory of JSON files, written atomically.
type Store struct {
	Dir string
}

func (s Store) LoadSeen() (seen.State, error) {
	var state seen.State
	err := s.read("seen.json", &state)
	if errors.Is(err, os.ErrNotExist) {
		return seen.New(), nil
	}
	if err != nil {
		return seen.New(), err
	}
	state.Normalize()
	return state, nil
}

func (s Store) SaveSeen(state seen.State) error {
	return s.write("seen.json", state)
}

func (s Store) LoadHistory() (history.List, error) {
	var list history.List
	err := s.read("history.json", &list)
	if errors.Is(err, os.ErrNotExist) {
		return history.List{}, nil
	}
	return list, err
}

func (s Store) SaveHistory(list history.List) error {
	return s.write("history.json", list)
}

// VersionsFile is the saved version check plus which CVEs are still unseen.
type VersionsFile struct {
	Report *version.Report `json:"report,omitempty"`
	Unseen []string        `json:"unseen,omitempty"`
}

func (s Store) LoadVersions() (VersionsFile, error) {
	var file VersionsFile
	err := s.read("versions.json", &file)
	if errors.Is(err, os.ErrNotExist) {
		return VersionsFile{}, nil
	}
	return file, err
}

func (s Store) SaveVersions(file VersionsFile) error {
	return s.write("versions.json", file)
}

func (s Store) read(name string, dest any) error {
	data, err := os.ReadFile(filepath.Join(s.Dir, name))
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, dest); err != nil {
		return err
	}
	return nil
}

func (s Store) write(name string, value any) error {
	if err := os.MkdirAll(s.Dir, 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	final := filepath.Join(s.Dir, name)
	tmp, err := os.CreateTemp(s.Dir, name+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, final)
}
