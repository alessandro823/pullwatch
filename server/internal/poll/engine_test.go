package poll

import (
	"context"
	"testing"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/history"
	"github.com/alessandro823/pullwatch/server/internal/model"
	"github.com/alessandro823/pullwatch/server/internal/provider"
	"github.com/alessandro823/pullwatch/server/internal/seen"
)

type fake struct {
	user    string
	open    []model.PullRequest
	tags    model.TagFetch
	tagErr  error
	synced  []model.PullRequest
	syncErr error
	openErr error

	opens int
	syncs int
	tagN  int
}

func (f *fake) CurrentUserID(context.Context) (string, error) {
	if f.openErr != nil {
		return "", f.openErr
	}
	return f.user, nil
}
func (f *fake) ListRepos(context.Context) ([]string, error) { return nil, nil }
func (f *fake) OpenPullRequests(context.Context) ([]model.PullRequest, error) {
	f.opens++
	if f.openErr != nil {
		return nil, f.openErr
	}
	return f.open, nil
}
func (f *fake) PullRequests(context.Context, *time.Time, int) ([]model.PullRequest, error) {
	f.syncs++
	if f.syncErr != nil {
		return nil, f.syncErr
	}
	return f.synced, nil
}
func (f *fake) Tags(context.Context, []string) (model.TagFetch, error) {
	f.tagN++
	if f.tagErr != nil {
		return model.TagFetch{}, f.tagErr
	}
	return f.tags, nil
}
func (f *fake) FilePaths(context.Context, string, string) ([]string, error) { return nil, nil }
func (f *fake) FileContent(context.Context, string, string, string) (string, error) {
	return "", nil
}
func (f *fake) Invalidate(context.Context) {}

func account() model.Account {
	return model.Account{
		ID: "gh", Kind: model.ProviderGitHub, DisplayName: "acme", Organization: "acme",
		NewRepoDefault: model.DefaultPRs, HideOwn: true,
		RepoWatch: map[string]model.WatchSet{
			"acme/api": {PRs: true, Tags: true, Completed: true, NotifyPRs: true, NotifyTags: true, NotifyCompleted: true},
		},
	}
}

func pull(n int, author string, at time.Time) model.PullRequest {
	return model.PullRequest{
		AccountID: "gh", Repo: "acme/api", Number: n, Title: "PR",
		AuthorID: author, AuthorName: author, CreatedAt: at, WebURL: "https://example.test", State: model.PROpen,
	}
}

func TestFirstPollIsSilentAndTheNextOneAnnounces(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	src := &fake{
		user: "me",
		open: []model.PullRequest{pull(1, "ada", now)},
		tags: model.TagFetch{Tags: []model.Tag{{AccountID: "gh", Repo: "acme/api", Name: "v1.0.0"}}},
	}
	clock := now
	engine := New(func(model.Account) provider.Source { return src }, seen.New(), nil, func() time.Time { return clock })
	acc := account()
	first := engine.Poll(context.Background(), []model.Account{acc}, 2*time.Minute, history.RetentionOneYear)
	if len(first.NewPullRequests) != 0 || len(first.NewTags) != 0 || first.Statuses["gh"].Kind != "ok" {
		t.Fatalf("first poll seeds: %+v", first)
	}
	src.open = append(src.open, pull(2, "bea", now.Add(time.Minute)))
	clock = now.Add(2 * time.Minute)
	second := engine.Poll(context.Background(), []model.Account{acc}, 2*time.Minute, history.RetentionOneYear)
	if len(second.NewPullRequests) != 1 || second.NewPullRequests[0].Number != 2 {
		t.Fatalf("new PR: %+v", second.NewPullRequests)
	}
	if len(second.NewTags) != 0 {
		t.Fatal("tags are not due yet")
	}
	src.tags.Tags = append(src.tags.Tags, model.Tag{AccountID: "gh", Repo: "acme/api", Name: "v1.1.0"})
	clock = now.Add(15 * time.Minute)
	third := engine.Poll(context.Background(), []model.Account{acc}, 2*time.Minute, history.RetentionOneYear)
	if len(third.NewTags) != 1 || third.NewTags[0].Name != "v1.1.0" {
		t.Fatalf("tags: %+v", third.NewTags)
	}
}

func TestDraftsOwnAndUnfollowedStayQuiet(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	src := &fake{user: "me", open: []model.PullRequest{pull(1, "ada", now)}}
	clock := now
	engine := New(func(model.Account) provider.Source { return src }, seen.New(), nil, func() time.Time { return clock })
	acc := account()
	engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionForever)
	draft := pull(2, "ada", now)
	draft.IsDraft = true
	mine := pull(3, "ME", now)
	other := pull(4, "ada", now)
	other.Repo = "acme/legacy"
	acc.RepoWatch["acme/legacy"] = model.WatchSet{}
	src.open = []model.PullRequest{pull(1, "ada", now), draft, mine, other}
	clock = now.Add(time.Minute)
	got := engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionForever)
	if len(got.NewPullRequests) != 0 {
		t.Fatalf("nothing here is announceable: %+v", got.NewPullRequests)
	}
}

func TestReadyForReviewIsNew(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	draft := pull(1, "ada", now)
	draft.IsDraft = true
	src := &fake{user: "me", open: []model.PullRequest{draft}}
	clock := now
	engine := New(func(model.Account) provider.Source { return src }, seen.New(), nil, func() time.Time { return clock })
	acc := account()
	engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionOneYear)
	draft.IsDraft = false
	src.open = []model.PullRequest{draft}
	clock = now.Add(time.Minute)
	got := engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionOneYear)
	if len(got.NewPullRequests) != 1 {
		t.Fatal("a draft that becomes ready is new")
	}
}

func TestCompletedMergesAfterTheFirstSync(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	src := &fake{user: "me"}
	clock := now
	engine := New(func(model.Account) provider.Source { return src }, seen.New(), nil, func() time.Time { return clock })
	acc := account()
	merged := pull(7, "ada", now.Add(-time.Hour))
	merged.State = model.PRMerged
	closed := now.Add(-30 * time.Minute)
	merged.ClosedAt = &closed
	src.synced = []model.PullRequest{merged}
	first := engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionOneYear)
	if len(first.CompletedPullRequests) != 0 || len(first.SyncedPullRequests) != 1 {
		t.Fatalf("first sync is silent: %+v", first)
	}
	clock = now.Add(15 * time.Minute)
	again := merged
	againClosed := clock.Add(-time.Minute)
	again.ClosedAt = &againClosed
	again.Number = 8
	src.synced = []model.PullRequest{merged, again}
	second := engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionOneYear)
	if len(second.CompletedPullRequests) != 1 || second.CompletedPullRequests[0].Number != 8 {
		t.Fatalf("completed: %+v", second.CompletedPullRequests)
	}
}

func TestBackoffAndRateLimitSkipWork(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	src := &fake{openErr: provider.Server(500)}
	clock := now
	engine := New(func(model.Account) provider.Source { return src }, seen.New(), nil, func() time.Time { return clock })
	acc := account()
	failed := engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionOneYear)
	if failed.Statuses["gh"].Kind != "failed" || src.opens != 0 {
		t.Fatalf("status %+v opens %d", failed.Statuses["gh"], src.opens)
	}
	// CurrentUserID fails before OpenPullRequests, so opens stays 0. Count user failures via a second poll being skipped.
	clock = now.Add(30 * time.Second)
	engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionOneYear)
	if src.opens != 0 {
		t.Fatal("backoff should skip the account")
	}

	src.openErr = provider.RateLimited(now.Add(10 * time.Minute))
	clock = now.Add(2 * time.Minute) // first failure delay is 2 minutes
	engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionOneYear)
	clock = now.Add(5 * time.Minute)
	before := src.tagN
	engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionOneYear)
	if src.tagN != before {
		t.Fatal("rate limit holds the account")
	}
}

func TestSyncFailureDoesNotFailTheAccount(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	src := &fake{user: "me", syncErr: provider.Network("timeout")}
	clock := now
	engine := New(func(model.Account) provider.Source { return src }, seen.New(), nil, func() time.Time { return clock })
	got := engine.Poll(context.Background(), []model.Account{account()}, time.Minute, history.RetentionOneYear)
	if got.Statuses["gh"].Kind != "ok" || len(got.SyncedPullRequests) != 0 {
		t.Fatalf("%+v", got.Statuses["gh"])
	}
}

func TestNewlyFollowedRepoIsSeeded(t *testing.T) {
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	src := &fake{user: "me", open: []model.PullRequest{pull(1, "ada", now)}}
	clock := now
	engine := New(func(model.Account) provider.Source { return src }, seen.New(), nil, func() time.Time { return clock })
	acc := account()
	acc.NewRepoDefault = model.DefaultNone
	acc.RepoWatch = map[string]model.WatchSet{"acme/api": model.WatchPRs()}
	engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionOneYear)
	extra := pull(2, "ada", now)
	extra.Repo = "acme/web"
	src.open = append(src.open, extra)
	acc.RepoWatch["acme/web"] = model.WatchPRs()
	clock = now.Add(time.Minute)
	got := engine.Poll(context.Background(), []model.Account{acc}, time.Minute, history.RetentionOneYear)
	if len(got.NewPullRequests) != 0 {
		t.Fatal("turning a repo on seeds its open pull requests")
	}
}
