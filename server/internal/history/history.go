// Package history is the persisted list of detected pull requests and tags.
package history

import (
	"strings"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/model"
)

type Kind string

const (
	KindPullRequest Kind = "pull_request"
	KindTag         Kind = "tag"
)

// Retention is how long detected items stay in the history.
type Retention string

const (
	RetentionTwoMonths Retention = "two_months"
	RetentionSixMonths Retention = "six_months"
	RetentionOneYear   Retention = "one_year"
	RetentionForever   Retention = "forever"
)

func (r Retention) MaxAge() *time.Duration {
	day := 24 * time.Hour
	var d time.Duration
	switch r {
	case RetentionTwoMonths:
		d = 61 * day
	case RetentionSixMonths:
		d = 183 * day
	case RetentionOneYear:
		d = 365 * day
	default:
		return nil
	}
	return &d
}

func (r Retention) Label() string {
	switch r {
	case RetentionTwoMonths:
		return "2 months"
	case RetentionSixMonths:
		return "6 months"
	case RetentionForever:
		return "Forever"
	default:
		return "1 year"
	}
}

// Entry is either a pull request or a tag.
type Entry struct {
	Kind        Kind               `json:"kind"`
	PullRequest *model.PullRequest `json:"pull_request,omitempty"`
	Tag         *model.Tag         `json:"tag,omitempty"`
}

func PREntry(pr model.PullRequest) Entry {
	return Entry{Kind: KindPullRequest, PullRequest: &pr}
}

func TagEntry(tag model.Tag) Entry {
	return Entry{Kind: KindTag, Tag: &tag}
}

func (e Entry) DedupKey() string {
	if e.Kind == KindTag && e.Tag != nil {
		return e.Tag.DedupKey()
	}
	if e.PullRequest != nil {
		return e.PullRequest.DedupKey()
	}
	return ""
}

func (e Entry) AccountID() string {
	if e.Kind == KindTag && e.Tag != nil {
		return e.Tag.AccountID
	}
	if e.PullRequest != nil {
		return e.PullRequest.AccountID
	}
	return ""
}

func (e Entry) Repo() string {
	if e.Kind == KindTag && e.Tag != nil {
		return e.Tag.Repo
	}
	if e.PullRequest != nil {
		return e.PullRequest.Repo
	}
	return ""
}

func (e Entry) Title() string {
	if e.Kind == KindTag && e.Tag != nil {
		return e.Tag.Name
	}
	if e.PullRequest != nil {
		return e.PullRequest.Title
	}
	return ""
}

func (e Entry) Author() string {
	if e.Kind == KindTag && e.Tag != nil {
		return e.Tag.AuthorName
	}
	if e.PullRequest != nil {
		return e.PullRequest.AuthorName
	}
	return ""
}

func (e Entry) WebURL() string {
	if e.Kind == KindTag && e.Tag != nil {
		return e.Tag.WebURL
	}
	if e.PullRequest != nil {
		return e.PullRequest.WebURL
	}
	return ""
}

func (e Entry) PRState() model.PRState {
	if e.PullRequest != nil && e.Kind == KindPullRequest {
		return e.PullRequest.State
	}
	return ""
}

// Item is one row in the history. Newest first.
type Item struct {
	Entry      Entry     `json:"entry"`
	DetectedAt time.Time `json:"detected_at"`
	IsRead     bool      `json:"is_read"`
}

func (it Item) ID() string { return it.Entry.DedupKey() }

// List is the whole history, newest first.
type List struct {
	Items []Item `json:"items"`
}

func (l *List) UnreadCount() int {
	n := 0
	for _, it := range l.Items {
		if !it.IsRead {
			n++
		}
	}
	return n
}

// Add inserts pull requests and tags at the top as unread.
// Tags from the same call end up above the pull requests.
// An existing row with the same id is replaced.
func (l *List) Add(prs []model.PullRequest, tags []model.Tag, at time.Time) {
	ordered := append([]model.PullRequest(nil), prs...)
	sortPRsByCreated(ordered)
	entries := make([]Entry, 0, len(ordered)+len(tags))
	for _, pr := range ordered {
		entries = append(entries, PREntry(pr))
	}
	for _, tag := range tags {
		entries = append(entries, TagEntry(tag))
	}
	for _, entry := range entries {
		l.removeID(entry.DedupKey())
		l.Items = append([]Item{{Entry: entry, DetectedAt: at, IsRead: false}}, l.Items...)
	}
}

// Merge inserts synced pull requests as already read (detectedAt = createdAt)
// or updates state, close date and title of an existing row.
// Pull requests created before notBefore are not added.
// Returns whether anything changed.
func (l *List) Merge(synced []model.PullRequest, notBefore *time.Time) bool {
	index := map[string]int{}
	for i, it := range l.Items {
		index[it.ID()] = i
	}
	existing := len(l.Items)
	changed := false
	for _, pr := range synced {
		key := pr.DedupKey()
		if i, ok := index[key]; ok {
			if update(&l.Items[i], pr) {
				changed = true
			}
			continue
		}
		if notBefore != nil && pr.CreatedAt.Before(*notBefore) {
			continue
		}
		index[key] = len(l.Items)
		l.Items = append(l.Items, Item{Entry: PREntry(pr), DetectedAt: pr.CreatedAt, IsRead: true})
		changed = true
	}
	if len(l.Items) > existing {
		// Stable: equal dates keep the previous order (existing rows before newly appended ones).
		type pair struct {
			i  int
			it Item
		}
		pairs := make([]pair, len(l.Items))
		for i, it := range l.Items {
			pairs[i] = pair{i, it}
		}
		for i := 1; i < len(pairs); i++ {
			j := i
			for j > 0 && (pairs[j].it.DetectedAt.After(pairs[j-1].it.DetectedAt) ||
				(pairs[j].it.DetectedAt.Equal(pairs[j-1].it.DetectedAt) && pairs[j].i < pairs[j-1].i)) {
				pairs[j], pairs[j-1] = pairs[j-1], pairs[j]
				j--
			}
		}
		for i, p := range pairs {
			l.Items[i] = p.it
		}
	}
	return changed
}

func update(it *Item, pr model.PullRequest) bool {
	if it.Entry.Kind != KindPullRequest || it.Entry.PullRequest == nil {
		return false
	}
	cur := it.Entry.PullRequest
	sameClose := (cur.ClosedAt == nil && pr.ClosedAt == nil) ||
		(cur.ClosedAt != nil && pr.ClosedAt != nil && cur.ClosedAt.Equal(*pr.ClosedAt))
	if cur.State == pr.State && sameClose && cur.Title == pr.Title {
		return false
	}
	cur.State = pr.State
	cur.ClosedAt = pr.ClosedAt
	cur.Title = pr.Title
	return true
}

// Surface moves id to the top and marks it unread. Used for a merge that
// should show up on the dashboard. Returns false when id is unknown.
func (l *List) Surface(id string, at time.Time) bool {
	for i, it := range l.Items {
		if it.ID() != id {
			continue
		}
		it.IsRead = false
		it.DetectedAt = at
		l.Items = append(l.Items[:i], l.Items[i+1:]...)
		l.Items = append([]Item{it}, l.Items...)
		return true
	}
	return false
}

func (l *List) MarkRead(id string) bool {
	for i := range l.Items {
		if l.Items[i].ID() == id {
			if l.Items[i].IsRead {
				return false
			}
			l.Items[i].IsRead = true
			return true
		}
	}
	return false
}

func (l *List) MarkAllRead() bool {
	changed := false
	for i := range l.Items {
		if !l.Items[i].IsRead {
			l.Items[i].IsRead = true
			changed = true
		}
	}
	return changed
}

func (l *List) RemoveAccount(id string) {
	out := l.Items[:0]
	for _, it := range l.Items {
		if it.Entry.AccountID() != id {
			out = append(out, it)
		}
	}
	l.Items = out
}

// Prune drops items older than the retention window.
func (l *List) Prune(now time.Time, retention Retention) bool {
	maxAge := retention.MaxAge()
	if maxAge == nil {
		return false
	}
	before := len(l.Items)
	out := l.Items[:0]
	for _, it := range l.Items {
		if now.Sub(it.DetectedAt) <= *maxAge {
			out = append(out, it)
		}
	}
	l.Items = out
	return len(l.Items) != before
}

// Search filters by kind and a case-insensitive query over title, author and repo.
// An empty query returns every item of that kind.
func (l List) Search(text string, kind Kind) []Item {
	query := strings.TrimSpace(text)
	var out []Item
	for _, it := range l.Items {
		if kind != "" && it.Entry.Kind != kind {
			continue
		}
		if query == "" ||
			strings.Contains(strings.ToLower(it.Entry.Title()), strings.ToLower(query)) ||
			strings.Contains(strings.ToLower(it.Entry.Author()), strings.ToLower(query)) ||
			strings.Contains(strings.ToLower(it.Entry.Repo()), strings.ToLower(query)) {
			out = append(out, it)
		}
	}
	return out
}

func (l List) Unread() []Item {
	var out []Item
	for _, it := range l.Items {
		if !it.IsRead {
			out = append(out, it)
		}
	}
	return out
}

func (l *List) removeID(id string) {
	out := l.Items[:0]
	for _, it := range l.Items {
		if it.ID() != id {
			out = append(out, it)
		}
	}
	l.Items = out
}

func sortPRsByCreated(prs []model.PullRequest) {
	for i := 1; i < len(prs); i++ {
		j := i
		for j > 0 && prs[j].CreatedAt.Before(prs[j-1].CreatedAt) {
			prs[j], prs[j-1] = prs[j-1], prs[j]
			j--
		}
	}
}
