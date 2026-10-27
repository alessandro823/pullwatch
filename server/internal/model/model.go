// Package model is the data the server shares with the Mac app: accounts, pull
// requests, tags and the per-repository watch settings.
package model

import (
	"strings"
	"time"
)

type ProviderKind string

const (
	ProviderGitHub      ProviderKind = "github"
	ProviderAzureDevOps ProviderKind = "azuredevops"
)

type PRState string

const (
	PROpen   PRState = "open"
	PRMerged PRState = "merged"
	PRClosed PRState = "closed"
)

// WatchSet is what is followed for one repository.
type WatchSet struct {
	PRs             bool `json:"prs" yaml:"prs"`
	Tags            bool `json:"tags" yaml:"tags"`
	Completed       bool `json:"completed" yaml:"completed"`
	NotifyPRs       bool `json:"notify_prs" yaml:"notify_prs"`
	NotifyTags      bool `json:"notify_tags" yaml:"notify_tags"`
	NotifyCompleted bool `json:"notify_completed" yaml:"notify_completed"`
}

func WatchPRs() WatchSet {
	return WatchSet{PRs: true, NotifyPRs: true, NotifyTags: true, NotifyCompleted: true}
}

func WatchNone() WatchSet {
	return WatchSet{NotifyPRs: true, NotifyTags: true, NotifyCompleted: true}
}

// NewRepoDefault applies to repositories without their own WatchSet.
// Tags are never on by default.
type NewRepoDefault string

const (
	DefaultNone NewRepoDefault = "none"
	DefaultPRs  NewRepoDefault = "prs"
)

func (d NewRepoDefault) WatchSet() WatchSet {
	if d == DefaultNone {
		return WatchNone()
	}
	return WatchPRs()
}

// Account is one GitHub owner or Azure DevOps organisation.
// Tokens are not stored here; the process reads them from the environment.
type Account struct {
	ID             string              `json:"id"`
	Kind           ProviderKind        `json:"kind"`
	DisplayName    string              `json:"display_name"`
	Organization   string              `json:"organization"`
	TokenEnv       string              `json:"token_env"`
	AzureAuth      string              `json:"azure_auth,omitempty"` // "pat" (default) or "bearer"
	RepoWatch      map[string]WatchSet `json:"repo_watch"`
	NewRepoDefault NewRepoDefault      `json:"new_repo_default"`
	IncludeDrafts  bool                `json:"include_drafts"`
	HideOwn        bool                `json:"hide_own"`
}

func (a Account) Pollable() bool {
	return strings.TrimSpace(a.Organization) != ""
}

func (a Account) Watch(repo string) WatchSet {
	return LookupWatch(repo, a.RepoWatch, a.NewRepoDefault)
}

// TagRepos are the repositories whose tags are followed, sorted and
// de-duplicated case-insensitively.
func (a Account) TagRepos() []string {
	var names []string
	for repo, set := range a.RepoWatch {
		if set.Tags {
			names = append(names, repo)
		}
	}
	return dedupeSorted(names)
}

func (a Account) FilterSettings() FilterSettings {
	return FilterSettings{
		Kind:           a.Kind,
		Organization:   a.Organization,
		RepoWatch:      a.RepoWatch,
		NewRepoDefault: a.NewRepoDefault,
		IncludeDrafts:  a.IncludeDrafts,
		HideOwn:        a.HideOwn,
	}
}

// FilterSettings is the slice of an account the poller remembers, so a
// settings change can be told apart from a genuinely new pull request.
type FilterSettings struct {
	Kind           ProviderKind        `json:"kind"`
	Organization   string              `json:"organization"`
	RepoWatch      map[string]WatchSet `json:"repo_watch"`
	NewRepoDefault NewRepoDefault      `json:"new_repo_default"`
	IncludeDrafts  bool                `json:"include_drafts"`
	HideOwn        bool                `json:"hide_own"`
}

func (s FilterSettings) Watch(repo string) WatchSet {
	return LookupWatch(repo, s.RepoWatch, s.NewRepoDefault)
}

func (s FilterSettings) SameSource(other FilterSettings) bool {
	return s.Kind == other.Kind && strings.EqualFold(s.Organization, other.Organization)
}

// SameSyncScope reports whether a history sync under other would return the
// same pull requests. Tag checkboxes do not count.
func (s FilterSettings) SameSyncScope(other FilterSettings) bool {
	if !s.SameSource(other) || s.NewRepoDefault != other.NewRepoDefault ||
		s.IncludeDrafts != other.IncludeDrafts || s.HideOwn != other.HideOwn {
		return false
	}
	a := s.prOverrides()
	b := other.prOverrides()
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

func (s FilterSettings) prOverrides() map[string]bool {
	base := s.NewRepoDefault.WatchSet().PRs
	out := map[string]bool{}
	for repo, set := range s.RepoWatch {
		if set.PRs != base {
			out[strings.ToLower(repo)] = set.PRs
		}
	}
	return out
}

func LookupWatch(repo string, watches map[string]WatchSet, fallback NewRepoDefault) WatchSet {
	if set, ok := watches[repo]; ok {
		return set
	}
	for key, set := range watches {
		if strings.EqualFold(key, repo) {
			return set
		}
	}
	return fallback.WatchSet()
}

// PullRequest is one pull request from either provider.
type PullRequest struct {
	AccountID  string     `json:"account_id"`
	Repo       string     `json:"repo"`
	Number     int        `json:"number"`
	Title      string     `json:"title"`
	AuthorID   string     `json:"author_id"`
	AuthorName string     `json:"author_name"`
	IsDraft    bool       `json:"is_draft"`
	CreatedAt  time.Time  `json:"created_at"`
	WebURL     string     `json:"web_url"`
	State      PRState    `json:"state"`
	ClosedAt   *time.Time `json:"closed_at,omitempty"`
}

func (p PullRequest) DedupKey() string {
	return p.AccountID + ":" + p.Repo + ":" + itoa(p.Number)
}

// Tag is a git tag on a followed repository.
type Tag struct {
	AccountID  string `json:"account_id"`
	Repo       string `json:"repo"`
	Name       string `json:"name"`
	AuthorName string `json:"author_name,omitempty"`
	WebURL     string `json:"web_url"`
}

func (t Tag) DedupKey() string {
	return t.AccountID + ":" + strings.ToLower(t.Repo) + ":tag:" + t.Name
}

// TagFetch is the result of listing tags. Unavailable repos were skipped
// (missing or no access) and must not be treated as empty.
type TagFetch struct {
	Tags             []Tag
	UnavailableRepos []string
}

func dedupeSorted(names []string) []string {
	if len(names) == 0 {
		return nil
	}
	sorted := append([]string(nil), names...)
	sortFold(sorted)
	out := make([]string, 0, len(sorted))
	seen := map[string]bool{}
	for _, name := range sorted {
		key := strings.ToLower(name)
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, name)
	}
	return out
}

func sortFold(s []string) {
	for i := 1; i < len(s); i++ {
		j := i
		for j > 0 && strings.ToLower(s[j]) < strings.ToLower(s[j-1]) {
			s[j], s[j-1] = s[j-1], s[j]
			j--
		}
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
