package history

import (
	"testing"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/model"
)

func pr(n int, title string, at time.Time) model.PullRequest {
	return model.PullRequest{
		AccountID: "a", Repo: "acme/api", Number: n, Title: title,
		AuthorName: "ada", CreatedAt: at, WebURL: "https://example.test", State: model.PROpen,
	}
}

func TestAddPutsTagsAbovePullRequests(t *testing.T) {
	var list List
	now := time.Now()
	list.Add([]model.PullRequest{
		pr(2, "second", now),
		pr(1, "first", now.Add(-time.Hour)),
	}, []model.Tag{{AccountID: "a", Repo: "acme/api", Name: "v1"}}, now)
	if len(list.Items) != 3 || list.Items[0].Entry.Title() != "v1" {
		t.Fatalf("tag should be first, got %#v", list.Items)
	}
	if list.Items[1].Entry.Title() != "second" || list.UnreadCount() != 3 {
		t.Fatalf("newest PR should follow the tag: %#v", list.Items[1])
	}
	list.Add([]model.PullRequest{pr(2, "renamed", now)}, nil, now)
	if len(list.Items) != 3 || list.Items[0].Entry.Title() != "renamed" {
		t.Fatal("adding an existing id replaces it at the top")
	}
}

func TestMergeUpdatesWithoutReopening(t *testing.T) {
	var list List
	now := time.Now()
	list.Add([]model.PullRequest{pr(1, "old", now.Add(-time.Hour))}, nil, now)
	closed := now
	updated := pr(1, "new title", now.Add(-time.Hour))
	updated.State = model.PRMerged
	updated.ClosedAt = &closed
	if !list.Merge([]model.PullRequest{updated}, nil) {
		t.Fatal("expected a change")
	}
	if list.Items[0].Entry.Title() != "new title" || list.Items[0].Entry.PRState() != model.PRMerged || list.Items[0].IsRead {
		t.Fatalf("merge should update in place and keep unread: %+v", list.Items[0])
	}
	if list.Items[0].DetectedAt.Equal(updated.CreatedAt) {
		t.Fatal("detected time of an existing row stays")
	}
	old := pr(9, "ancient", now.Add(-48*time.Hour))
	cutoff := now.Add(-24 * time.Hour)
	if list.Merge([]model.PullRequest{old}, &cutoff) {
		t.Fatal("pull requests created before the cutoff are not added")
	}
}

func TestMergeSortsNewRowsByDetectedTime(t *testing.T) {
	var list List
	now := time.Now()
	list.Add([]model.PullRequest{pr(1, "recent", now)}, nil, now)
	older := pr(2, "older", now.Add(-2*time.Hour))
	list.Merge([]model.PullRequest{older}, nil)
	if list.Items[0].Entry.Title() != "recent" || list.Items[1].Entry.Title() != "older" || !list.Items[1].IsRead {
		t.Fatalf("synced rows are read and ordered by detected time: %+v", list.Items)
	}
}

func TestPruneSearchAndRead(t *testing.T) {
	var list List
	now := time.Now()
	list.Add([]model.PullRequest{pr(1, "Keep me", now)}, []model.Tag{{AccountID: "a", Repo: "acme/api", Name: "v2", AuthorName: "bea"}}, now)
	list.Add([]model.PullRequest{pr(2, "Old", now.Add(-100*24*time.Hour))}, nil, now.Add(-100*24*time.Hour))
	if !list.Prune(now, RetentionTwoMonths) || len(list.Items) != 2 {
		t.Fatalf("prune dropped the wrong rows: %d", len(list.Items))
	}
	if len(list.Search("BEA", KindTag)) != 1 || len(list.Search("keep", "")) != 1 {
		t.Fatal("search should match author and title, case-insensitive")
	}
	if !list.MarkRead(list.Items[0].ID()) || list.UnreadCount() != 1 {
		t.Fatal("mark read")
	}
	if !list.MarkAllRead() || list.UnreadCount() != 0 {
		t.Fatal("mark all")
	}
	if list.Prune(now, RetentionForever) {
		t.Fatal("forever keeps everything")
	}
}
