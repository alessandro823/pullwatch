package filter

import (
	"testing"

	"github.com/alessandro823/pullwatch/server/internal/model"
)

func settings(watch map[string]model.WatchSet, def model.NewRepoDefault, drafts, hideOwn bool) model.FilterSettings {
	return model.FilterSettings{
		Kind: model.ProviderGitHub, Organization: "Acme",
		RepoWatch: watch, NewRepoDefault: def, IncludeDrafts: drafts, HideOwn: hideOwn,
	}
}

func pr(repo, author string, draft bool) model.PullRequest {
	return model.PullRequest{Repo: repo, AuthorID: author, Title: "t"}
}

func TestFollowsDefaultAndOverrides(t *testing.T) {
	deny := settings(map[string]model.WatchSet{"proj/legacy": model.WatchNone()}, model.DefaultPRs, false, true)
	if !Follows("proj/api", deny) || Follows("proj/legacy", deny) {
		t.Fatal("default prs follows everything except an explicit none")
	}
	allow := settings(map[string]model.WatchSet{"proj/api": model.WatchPRs()}, model.DefaultNone, false, true)
	if !Follows("proj/api", allow) || Follows("proj/web", allow) {
		t.Fatal("default none follows only listed repos")
	}
	if !Follows("proj/myrepo", settings(map[string]model.WatchSet{"Proj/MyRepo": model.WatchPRs()}, model.DefaultNone, false, true)) {
		t.Fatal("repo match is case-insensitive")
	}
}

func TestDraftsAndOwnPullRequests(t *testing.T) {
	draft := pr("proj/api", "someone", true)
	draft.IsDraft = true
	hidden := settings(nil, model.DefaultPRs, false, true)
	if Passes(draft, hidden, "me", WatchPRs) {
		t.Fatal("drafts are hidden")
	}
	shown := hidden
	shown.IncludeDrafts = true
	if !Passes(draft, shown, "me", WatchPRs) {
		t.Fatal("drafts pass when included")
	}
	mine := pr("proj/api", "ME", false)
	if Passes(mine, hidden, "me", WatchPRs) {
		t.Fatal("own pull requests are hidden")
	}
	open := hidden
	open.HideOwn = false
	if !Passes(mine, open, "me", WatchPRs) {
		t.Fatal("own pull requests pass when hide_own is off")
	}
}

func TestCompletedCheckboxIsIndependent(t *testing.T) {
	set := model.WatchPRs()
	set.Completed = false
	s := settings(map[string]model.WatchSet{"proj/api": set}, model.DefaultNone, false, true)
	item := pr("proj/api", "a", false)
	if !Passes(item, s, "me", WatchPRs) || Passes(item, s, "me", WatchCompleted) {
		t.Fatal("completed is a separate checkbox")
	}
}

func TestSameSourceAndSyncScope(t *testing.T) {
	a := settings(nil, model.DefaultPRs, false, true)
	b := a
	b.Organization = "acme"
	tagged := model.WatchPRs()
	tagged.Tags = true
	b.RepoWatch = map[string]model.WatchSet{"x/y": tagged}
	if !a.SameSource(b) || !a.SameSyncScope(b) {
		t.Fatal("tag-only overrides do not change the sync scope")
	}
	c := a
	c.Kind = model.ProviderAzureDevOps
	if a.SameSource(c) {
		t.Fatal("kind is part of the source")
	}
	d := a
	d.RepoWatch = map[string]model.WatchSet{"x/y": model.WatchNone()}
	if a.SameSyncScope(d) {
		t.Fatal("a PR override changes the sync scope")
	}
}
