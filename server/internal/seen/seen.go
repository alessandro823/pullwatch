// Package seen remembers which pull requests and tags have already been
// observed, so a restart does not announce them again.
package seen

import (
	"strings"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/history"
	"github.com/alessandro823/pullwatch/server/internal/model"
)

const maxAge = 30 * 24 * time.Hour

// State is the dedup record persisted between polls.
type State struct {
	// Seen maps a dedup key to the last time it was observed open (or seeded).
	Seen         map[string]time.Time            `json:"seen"`
	LastSettings map[string]model.FilterSettings `json:"last_settings"`
	// TagSeeded maps "{account}:{repo}" to the last successful tag poll.
	// The first poll of a repository is silent.
	TagSeeded map[string]time.Time `json:"tag_seeded"`
	SyncMarks map[string]SyncMark  `json:"sync_marks"`
}

func New() State {
	return State{
		Seen:         map[string]time.Time{},
		LastSettings: map[string]model.FilterSettings{},
		TagSeeded:    map[string]time.Time{},
		SyncMarks:    map[string]SyncMark{},
	}
}

// Normalize fills nil maps so callers can write without a nil check.
func (s *State) Normalize() {
	if s.Seen == nil {
		s.Seen = map[string]time.Time{}
	}
	if s.LastSettings == nil {
		s.LastSettings = map[string]model.FilterSettings{}
	}
	if s.TagSeeded == nil {
		s.TagSeeded = map[string]time.Time{}
	}
	if s.SyncMarks == nil {
		s.SyncMarks = map[string]SyncMark{}
	}
}

func (s *State) Contains(key string) bool {
	s.Normalize()
	_, ok := s.Seen[key]
	return ok
}

func (s *State) Mark(key string, at time.Time) {
	s.Normalize()
	s.Seen[key] = at
}

// SyncMark is the last successful history sync for an account.
type SyncMark struct {
	At        time.Time            `json:"at"`
	Settings  model.FilterSettings `json:"settings"`
	Retention history.Retention    `json:"retention"`
}

// Prune drops seen and tag-seed entries older than 30 days whose key has one
// of the prefixes. Other accounts are left alone so a long outage does not
// forget them.
func (s *State) Prune(now time.Time, prefixes []string) {
	s.Normalize()
	s.Seen = pruneMap(s.Seen, now, prefixes)
	s.TagSeeded = pruneMap(s.TagSeeded, now, prefixes)
}

func pruneMap(m map[string]time.Time, now time.Time, prefixes []string) map[string]time.Time {
	out := map[string]time.Time{}
	for key, at := range m {
		if hasPrefix(key, prefixes) && now.Sub(at) > maxAge {
			continue
		}
		out[key] = at
	}
	return out
}

// Retain drops entries whose key does not start with one of the prefixes.
func (s *State) Retain(prefixes []string) {
	s.Normalize()
	s.Seen = retainMap(s.Seen, prefixes)
	s.TagSeeded = retainMap(s.TagSeeded, prefixes)
}

func retainMap(m map[string]time.Time, prefixes []string) map[string]time.Time {
	out := map[string]time.Time{}
	for key, at := range m {
		if hasPrefix(key, prefixes) {
			out[key] = at
		}
	}
	return out
}

func hasPrefix(key string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(key, p) {
			return true
		}
	}
	return false
}
