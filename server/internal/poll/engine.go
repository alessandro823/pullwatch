// Package poll decides which pull requests and tags are new.
// The first successful poll of an account, and the first tag poll of a
// repository, are silent: existing items are remembered and not announced.
package poll

import (
	"context"
	"encoding/json"
	"log/slog"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/backoff"
	"github.com/alessandro823/pullwatch/server/internal/filter"
	"github.com/alessandro823/pullwatch/server/internal/history"
	"github.com/alessandro823/pullwatch/server/internal/model"
	"github.com/alessandro823/pullwatch/server/internal/provider"
	"github.com/alessandro823/pullwatch/server/internal/seen"
)

const (
	TagInterval      = 15 * time.Minute
	syncLimit        = 1000
	syncOverlap      = time.Hour
	maxRateLimitWait = time.Hour
	maxBackoff       = 900 * time.Second
)

// State is the per-account health shown on the dashboard.
type State struct {
	Kind     string    `json:"kind"` // idle, ok, failed
	LastPoll time.Time `json:"last_poll,omitempty"`
	Since    time.Time `json:"since,omitempty"`
	Message  string    `json:"message,omitempty"`
	// Unauthorized is true when the failure is a bad token.
	Unauthorized bool `json:"unauthorized,omitempty"`
}

// Result is one poll cycle across every account.
type Result struct {
	NewPullRequests       []model.PullRequest
	NewTags               []model.Tag
	Statuses              map[string]State
	AuthFailures          []string
	SyncedPullRequests    []model.PullRequest
	CompletedPullRequests []model.PullRequest
}

type schedule struct {
	nextDue          time.Time
	nextTagDue       time.Time
	nextSyncDue      time.Time
	failures         int
	rateLimitedUntil time.Time
}

type cached struct {
	fp  string
	src provider.Source
}

// Engine polls accounts on their own schedule.
type Engine struct {
	mu        sync.Mutex
	make      func(model.Account) provider.Source
	state     seen.State
	save      func(seen.State) error
	now       func() time.Time
	providers map[string]cached
	userIDs   map[string]string
	schedules map[string]schedule
	statuses  map[string]State
	inFlight  map[string]bool
	firstSync string
}

func New(make func(model.Account) provider.Source, initial seen.State, save func(seen.State) error, now func() time.Time) *Engine {
	if now == nil {
		now = time.Now
	}
	initial.Normalize()
	return &Engine{
		make:      make,
		state:     initial,
		save:      save,
		now:       now,
		providers: map[string]cached{},
		userIDs:   map[string]string{},
		schedules: map[string]schedule{},
		statuses:  map[string]State{},
		inFlight:  map[string]bool{},
	}
}

// ResetHistorySync forgets sync marks so the next poll backfills history again.
func (e *Engine) ResetHistorySync() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.state.SyncMarks = map[string]seen.SyncMark{}
	e.forceRefreshLocked()
}

// ForceRefresh makes every account due now, unless it is waiting out a rate limit.
func (e *Engine) ForceRefresh() {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.forceRefreshLocked()
}

func (e *Engine) forceRefreshLocked() {
	t := e.now()
	for id, sch := range e.schedules {
		if sch.rateLimitedUntil.After(t) {
			continue
		}
		sch.nextDue = t
		sch.nextTagDue = t
		sch.nextSyncDue = t
		e.schedules[id] = sch
	}
}

// Statuses is the last known health of each account.
func (e *Engine) Statuses() map[string]State {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := map[string]State{}
	for id, st := range e.statuses {
		out[id] = st
	}
	return out
}

type syncRequest struct {
	since   *time.Time
	isFirst bool
}

type job struct {
	account  model.Account
	src      provider.Source
	userID   string
	tagRepos []string
	doTags   bool
	sync     *syncRequest
}

type fetched struct {
	userID              string
	pullRequests        []model.PullRequest
	tags                *model.TagFetch
	tagRepos            []string
	unavailableTagRepos map[string]bool
	tagError            *provider.Error
	synced              *[]model.PullRequest
	syncError           *provider.Error
}

// Poll fetches every account that is due and returns what is new.
func (e *Engine) Poll(ctx context.Context, accounts []model.Account, interval time.Duration, retention history.Retention) Result {
	e.mu.Lock()
	t := e.now()
	keep := map[string]bool{}
	for _, a := range accounts {
		keep[a.ID] = true
	}
	e.forget(keep)

	var jobs []job
	for _, account := range accounts {
		if e.inFlight[account.ID] {
			continue
		}
		sch := e.schedules[account.ID]
		if !sch.nextDue.IsZero() && sch.nextDue.After(t) {
			continue
		}
		tagsDue := sch.nextTagDue.IsZero() || !sch.nextTagDue.After(t)
		syncDue := sch.nextSyncDue.IsZero() || !sch.nextSyncDue.After(t)
		var sync *syncRequest
		if syncDue {
			sync = e.syncRequest(account, retention, t)
			if sync.isFirst {
				if e.firstSync == "" {
					e.firstSync = account.ID
				} else {
					sync = nil
				}
			}
		}
		j := job{
			account:  account,
			src:      e.provider(account),
			userID:   e.userIDs[account.ID],
			tagRepos: account.TagRepos(),
			doTags:   tagsDue && len(account.TagRepos()) > 0,
			sync:     sync,
		}
		jobs = append(jobs, j)
		e.inFlight[account.ID] = true
	}
	e.mu.Unlock()

	type outcome struct {
		id  string
		got fetched
		err *provider.Error
	}
	out := make([]outcome, len(jobs))
	var wg sync.WaitGroup
	for i, j := range jobs {
		wg.Add(1)
		go func(i int, j job) {
			defer wg.Done()
			got, err := fetch(ctx, j)
			if err != nil {
				out[i] = outcome{id: j.account.ID, err: err}
				return
			}
			out[i] = outcome{id: j.account.ID, got: got}
		}(i, j)
	}
	wg.Wait()

	e.mu.Lock()
	defer e.mu.Unlock()
	var result Result
	var succeeded []string
	for i, oc := range out {
		j := jobs[i]
		if oc.err != nil {
			if e.handleFailure(j.account, j.src, oc.err, t, interval) {
				result.AuthFailures = append(result.AuthFailures, j.account.ID)
			}
		} else {
			freshPRs, freshTags := e.handleSuccess(j.account, oc.got, t, interval)
			result.NewPullRequests = append(result.NewPullRequests, freshPRs...)
			result.NewTags = append(result.NewTags, freshTags...)
			synced, completed := e.handleSync(j.account, oc.got, j.sync, retention, t)
			result.SyncedPullRequests = append(result.SyncedPullRequests, synced...)
			result.CompletedPullRequests = append(result.CompletedPullRequests, completed...)
			succeeded = append(succeeded, j.account.ID)
		}
		delete(e.inFlight, j.account.ID)
		if e.firstSync == j.account.ID {
			e.firstSync = ""
		}
	}

	prefixes := make([]string, len(succeeded))
	for i, id := range succeeded {
		prefixes[i] = id + ":"
	}
	e.state.Prune(t, prefixes)
	if e.save != nil {
		if err := e.save(e.state); err != nil {
			slog.Error("save seen state", "err", err)
		}
	}

	sort.SliceStable(result.NewPullRequests, func(i, j int) bool {
		return result.NewPullRequests[i].CreatedAt.Before(result.NewPullRequests[j].CreatedAt)
	})
	sort.SliceStable(result.NewTags, func(i, j int) bool {
		a, b := result.NewTags[i], result.NewTags[j]
		if a.Repo != b.Repo {
			return a.Repo < b.Repo
		}
		return a.Name < b.Name
	})
	sort.SliceStable(result.CompletedPullRequests, func(i, j int) bool {
		ai, aj := result.CompletedPullRequests[i].ClosedAt, result.CompletedPullRequests[j].ClosedAt
		var ti, tj time.Time
		if ai != nil {
			ti = *ai
		}
		if aj != nil {
			tj = *aj
		}
		return ti.Before(tj)
	})
	result.Statuses = map[string]State{}
	for _, account := range accounts {
		if st, ok := e.statuses[account.ID]; ok {
			result.Statuses[account.ID] = st
		} else {
			result.Statuses[account.ID] = State{Kind: "idle"}
		}
	}
	return result
}

func fetch(ctx context.Context, j job) (fetched, *provider.Error) {
	userID := j.userID
	if userID == "" {
		id, err := j.src.CurrentUserID(ctx)
		if err != nil {
			return fetched{}, asProvider(err)
		}
		userID = id
	}
	prs, err := j.src.OpenPullRequests(ctx)
	if err != nil {
		return fetched{}, asProvider(err)
	}
	var tags *model.TagFetch
	var tagErr *provider.Error
	if j.doTags {
		tf, err := j.src.Tags(ctx, j.tagRepos)
		if err != nil {
			pe := asProvider(err)
			if pe.Kind == provider.KindRateLimited {
				return fetched{}, pe
			}
			tagErr = pe
		} else {
			tags = &tf
		}
	}
	var synced *[]model.PullRequest
	var syncErr *provider.Error
	if j.sync != nil {
		list, err := j.src.PullRequests(ctx, j.sync.since, syncLimit)
		if err != nil {
			syncErr = asProvider(err)
		} else {
			synced = &list
		}
	}
	unavailable := map[string]bool{}
	if tags != nil {
		for _, repo := range tags.UnavailableRepos {
			unavailable[strings.ToLower(repo)] = true
		}
	}
	return fetched{
		userID:              userID,
		pullRequests:        prs,
		tags:                tags,
		tagRepos:            j.tagRepos,
		unavailableTagRepos: unavailable,
		tagError:            tagErr,
		synced:              synced,
		syncError:           syncErr,
	}, nil
}

func (e *Engine) syncRequest(account model.Account, retention history.Retention, t time.Time) *syncRequest {
	if mark, ok := e.state.SyncMarks[account.ID]; ok &&
		mark.Settings.SameSyncScope(account.FilterSettings()) && mark.Retention == retention {
		since := mark.At.Add(-syncOverlap)
		return &syncRequest{since: &since, isFirst: false}
	}
	req := &syncRequest{isFirst: true}
	if max := retention.MaxAge(); max != nil {
		since := t.Add(-*max)
		req.since = &since
	}
	return req
}

func (e *Engine) provider(account model.Account) provider.Source {
	fp := fingerprint(account)
	if c, ok := e.providers[account.ID]; ok && c.fp == fp {
		return c.src
	}
	src := e.make(account)
	e.providers[account.ID] = cached{fp: fp, src: src}
	delete(e.userIDs, account.ID)
	return src
}

func (e *Engine) forget(ids map[string]bool) {
	for id := range e.providers {
		if !ids[id] {
			delete(e.providers, id)
		}
	}
	for id := range e.userIDs {
		if !ids[id] {
			delete(e.userIDs, id)
		}
	}
	for id := range e.schedules {
		if !ids[id] {
			delete(e.schedules, id)
		}
	}
	for id := range e.statuses {
		if !ids[id] {
			delete(e.statuses, id)
		}
	}
	for id := range e.state.LastSettings {
		if !ids[id] {
			delete(e.state.LastSettings, id)
		}
	}
	for id := range e.state.SyncMarks {
		if !ids[id] {
			delete(e.state.SyncMarks, id)
		}
	}
	var prefixes []string
	for id := range ids {
		prefixes = append(prefixes, id+":")
	}
	e.state.Retain(prefixes)
}

func (e *Engine) handleSuccess(account model.Account, got fetched, t time.Time, interval time.Duration) ([]model.PullRequest, []model.Tag) {
	settings := account.FilterSettings()
	var previous *model.FilterSettings
	if prev, ok := e.state.LastSettings[account.ID]; ok && prev.SameSource(settings) {
		previous = &prev
	}
	var fresh []model.PullRequest
	for _, pr := range got.pullRequests {
		if !filter.Passes(pr, settings, got.userID, filter.WatchPRs) {
			continue
		}
		if !e.state.Contains(pr.DedupKey()) && previous != nil &&
			filter.Passes(pr, *previous, got.userID, filter.WatchPRs) {
			fresh = append(fresh, pr)
		}
		e.state.Mark(pr.DedupKey(), t)
	}
	e.state.LastSettings[account.ID] = cloneSettings(settings)
	e.userIDs[account.ID] = got.userID
	prevSch := e.schedules[account.ID]
	sch := schedule{nextDue: t.Add(interval), nextTagDue: prevSch.nextTagDue, nextSyncDue: prevSch.nextSyncDue}
	if got.tags != nil || got.tagError != nil {
		sch.nextTagDue = t.Add(TagInterval)
	}
	if got.tagError != nil {
		slog.Warn("tags failed", "account", account.DisplayName, "err", got.tagError.UserMessage())
	}
	e.schedules[account.ID] = sch
	e.statuses[account.ID] = State{Kind: "ok", LastPoll: t}
	return fresh, e.handleTags(account, got, t)
}

func (e *Engine) handleSync(account model.Account, got fetched, request *syncRequest, retention history.Retention, t time.Time) ([]model.PullRequest, []model.PullRequest) {
	sch := e.schedules[account.ID]
	defer func() { e.schedules[account.ID] = sch }()
	if got.syncError != nil {
		if got.syncError.Kind == provider.KindRateLimited {
			until := got.syncError.Until
			if until.After(t.Add(maxRateLimitWait)) {
				until = t.Add(maxRateLimitWait)
			}
			sch.nextSyncDue = until
		} else {
			sch.nextSyncDue = t.Add(TagInterval)
		}
		slog.Warn("history sync failed", "account", account.DisplayName, "err", got.syncError.UserMessage())
		return nil, nil
	}
	if got.synced == nil {
		return nil, nil
	}
	settings := account.FilterSettings()
	var previous *seen.SyncMark
	if request != nil && !request.isFirst {
		if mark, ok := e.state.SyncMarks[account.ID]; ok {
			previous = &mark
		}
	}
	completed := e.completed(account, *got.synced, previous, got.userID, t)
	e.state.SyncMarks[account.ID] = seen.SyncMark{At: t, Settings: cloneSettings(settings), Retention: retention}
	sch.nextSyncDue = t.Add(TagInterval)
	var visible []model.PullRequest
	for _, pr := range *got.synced {
		if filter.Passes(pr, settings, got.userID, filter.WatchPRs) {
			visible = append(visible, pr)
		}
	}
	return visible, completed
}

func (e *Engine) completed(account model.Account, synced []model.PullRequest, previous *seen.SyncMark, userID string, t time.Time) []model.PullRequest {
	settings := account.FilterSettings()
	var fresh []model.PullRequest
	for _, pr := range synced {
		if pr.State != model.PRMerged {
			continue
		}
		if !filter.Passes(pr, settings, userID, filter.WatchCompleted) {
			continue
		}
		key := pr.DedupKey() + ":completed"
		if previous != nil && !e.state.Contains(key) &&
			filter.Passes(pr, previous.Settings, userID, filter.WatchCompleted) &&
			pr.ClosedAt != nil && !pr.ClosedAt.Before(previous.At.Add(-syncOverlap)) {
			fresh = append(fresh, pr)
		}
		e.state.Mark(key, t)
	}
	return fresh
}

func (e *Engine) handleTags(account model.Account, got fetched, t time.Time) []model.Tag {
	if got.tagError != nil {
		return nil
	}
	prefix := account.ID + ":"
	wanted := map[string]bool{}
	for _, repo := range got.tagRepos {
		wanted[prefix+strings.ToLower(repo)] = true
	}
	for key := range e.state.TagSeeded {
		if strings.HasPrefix(key, prefix) && !wanted[key] {
			delete(e.state.TagSeeded, key)
		}
	}
	if got.tags == nil {
		return nil
	}
	byRepo := map[string][]model.Tag{}
	for _, tag := range got.tags.Tags {
		byRepo[strings.ToLower(tag.Repo)] = append(byRepo[strings.ToLower(tag.Repo)], tag)
	}
	if len(got.unavailableTagRepos) > 0 {
		var names []string
		for name := range got.unavailableTagRepos {
			names = append(names, name)
		}
		sort.Strings(names)
		slog.Warn("tags skipped", "account", account.DisplayName, "repos", strings.Join(names, ", "))
	}
	var fresh []model.Tag
	seenRepo := map[string]bool{}
	for _, repo := range got.tagRepos {
		low := strings.ToLower(repo)
		if seenRepo[low] || got.unavailableTagRepos[low] {
			seenRepo[low] = true
			continue
		}
		seenRepo[low] = true
		seededKey := prefix + low
		_, seeded := e.state.TagSeeded[seededKey]
		for _, tag := range byRepo[low] {
			if seeded && !e.state.Contains(tag.DedupKey()) {
				fresh = append(fresh, tag)
			}
			e.state.Mark(tag.DedupKey(), t)
		}
		e.state.TagSeeded[seededKey] = t
	}
	return fresh
}

func (e *Engine) handleFailure(account model.Account, src provider.Source, err *provider.Error, t time.Time, interval time.Duration) bool {
	sch := e.schedules[account.ID]
	sch.failures++
	if err.Kind == provider.KindRateLimited {
		until := err.Until
		if until.After(t.Add(maxRateLimitWait)) {
			until = t.Add(maxRateLimitWait)
		}
		sch.rateLimitedUntil = until
		sch.nextDue = until
	} else {
		sch.rateLimitedUntil = time.Time{}
		sch.nextDue = t.Add(backoff.Delay(interval, sch.failures, maxBackoff))
	}
	e.schedules[account.ID] = sch

	wasUnauthorized := false
	if prev, ok := e.statuses[account.ID]; ok && prev.Kind == "failed" && sameFailure(prev, err) {
		wasUnauthorized = prev.Unauthorized
		e.statuses[account.ID] = State{Kind: "failed", Since: prev.Since, Message: err.UserMessage(), Unauthorized: err.Kind == provider.KindUnauthorized}
	} else {
		e.statuses[account.ID] = State{Kind: "failed", Since: t, Message: err.UserMessage(), Unauthorized: err.Kind == provider.KindUnauthorized}
	}
	slog.Warn("poll failed", "account", account.DisplayName, "err", err.UserMessage())
	if err.Kind != provider.KindUnauthorized {
		return false
	}
	delete(e.userIDs, account.ID)
	src.Invalidate(context.Background())
	return !wasUnauthorized
}

func sameFailure(prev State, err *provider.Error) bool {
	if err.Kind == provider.KindUnauthorized {
		return prev.Unauthorized
	}
	return prev.Message == err.UserMessage()
}

func asProvider(err error) *provider.Error {
	if err == nil {
		return nil
	}
	if pe, ok := provider.AsError(err); ok {
		return pe
	}
	return provider.Network(err.Error())
}

func cloneSettings(s model.FilterSettings) model.FilterSettings {
	out := s
	if s.RepoWatch != nil {
		out.RepoWatch = make(map[string]model.WatchSet, len(s.RepoWatch))
		for key, value := range s.RepoWatch {
			out.RepoWatch[key] = value
		}
	}
	return out
}

func fingerprint(account model.Account) string {
	b, err := json.Marshal(account)
	if err != nil {
		return account.ID
	}
	return string(b)
}
