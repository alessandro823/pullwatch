// Package filter decides which pull requests a followed account should surface.
package filter

import (
	"strings"

	"github.com/alessandro823/pullwatch/server/internal/model"
)

// Watching selects which checkbox must be on: pull requests or completed merges.
type Watching int

const (
	WatchPRs Watching = iota
	WatchCompleted
)

// Follows reports whether pull requests in repo are followed.
func Follows(repo string, settings model.FilterSettings) bool {
	return settings.Watch(repo).PRs
}

// Passes reports whether pr is visible under settings.
func Passes(pr model.PullRequest, settings model.FilterSettings, currentUserID string, watching Watching) bool {
	set := settings.Watch(pr.Repo)
	on := set.PRs
	if watching == WatchCompleted {
		on = set.Completed
	}
	if !on {
		return false
	}
	if pr.IsDraft && !settings.IncludeDrafts {
		return false
	}
	if settings.HideOwn && currentUserID != "" && strings.EqualFold(pr.AuthorID, currentUserID) {
		return false
	}
	return true
}
