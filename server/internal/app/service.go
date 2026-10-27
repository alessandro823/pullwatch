// Package app wires polling, the version check and the dashboard together.
package app

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/azure"
	"github.com/alessandro823/pullwatch/server/internal/config"
	"github.com/alessandro823/pullwatch/server/internal/github"
	"github.com/alessandro823/pullwatch/server/internal/history"
	"github.com/alessandro823/pullwatch/server/internal/model"
	"github.com/alessandro823/pullwatch/server/internal/poll"
	"github.com/alessandro823/pullwatch/server/internal/provider"
	"github.com/alessandro823/pullwatch/server/internal/seen"
	"github.com/alessandro823/pullwatch/server/internal/store"
	"github.com/alessandro823/pullwatch/server/internal/version"
	"github.com/alessandro823/pullwatch/server/internal/web"
)

// Service is the running server.
type Service struct {
	cfg    config.Config
	store  store.Store
	engine *poll.Engine
	client *http.Client

	mu        sync.Mutex
	hist      history.List
	report    *version.Report
	unseen    map[string]bool
	checking  bool
	demo      bool
	lastCheck time.Time
	retryAt   time.Time
}

// Open loads state from disk and gets ready to poll.
func Open(cfg config.Config) (*Service, error) {
	st := store.Store{Dir: cfg.DataDir}
	if err := os.MkdirAll(cfg.DataDir, 0o755); err != nil {
		return nil, err
	}
	seenState, err := st.LoadSeen()
	if err != nil {
		slog.Error("seen state unreadable, starting empty", "err", err)
		seenState = seen.New()
	}
	hist, err := st.LoadHistory()
	if err != nil {
		slog.Error("history unreadable, starting empty", "err", err)
		hist = history.List{}
	}
	versions, err := st.LoadVersions()
	if err != nil {
		slog.Error("versions unreadable, starting empty", "err", err)
		versions = store.VersionsFile{}
	}
	s := &Service{
		cfg:    cfg,
		store:  st,
		client: &http.Client{Timeout: 30 * time.Second},
		hist:   hist,
		report: versions.Report,
		unseen: map[string]bool{},
		demo:   false,
	}
	for _, key := range versions.Unseen {
		s.unseen[key] = true
	}
	if s.report != nil {
		s.lastCheck = s.report.CheckedAt
	}
	s.engine = poll.New(s.provider, seenState, st.SaveSeen, time.Now)
	return s, nil
}

// Run polls in the background and serves the dashboard until ctx is cancelled.
func (s *Service) Run(ctx context.Context) error {
	if !s.demo {
		go s.pollLoop(ctx)
		go s.versionLoop(ctx)
	}
	return s.serve(ctx)
}

func (s *Service) pollLoop(ctx context.Context) {
	s.poll(ctx)
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.poll(ctx)
		}
	}
}

func (s *Service) poll(ctx context.Context) {
	result := s.engine.Poll(ctx, s.pollable(), s.cfg.PollInterval, s.cfg.HistoryRetention)
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	changed := false
	if len(result.NewPullRequests) > 0 || len(result.NewTags) > 0 {
		s.hist.Add(result.NewPullRequests, result.NewTags, now)
		changed = true
	}
	var cutoff *time.Time
	if max := s.cfg.HistoryRetention.MaxAge(); max != nil {
		t := now.Add(-*max)
		cutoff = &t
	}
	if s.hist.Merge(result.SyncedPullRequests, cutoff) {
		changed = true
	}
	for _, pr := range result.CompletedPullRequests {
		if !s.hist.Surface(pr.DedupKey(), now) {
			s.hist.Add([]model.PullRequest{pr}, nil, now)
		}
		changed = true
	}
	if s.hist.Prune(now, s.cfg.HistoryRetention) {
		changed = true
	}
	if changed {
		if err := s.store.SaveHistory(s.hist); err != nil {
			slog.Error("save history", "err", err)
		}
	}
	if len(result.AuthFailures) > 0 {
		slog.Warn("token rejected", "accounts", strings.Join(result.AuthFailures, ","))
	}
}

func (s *Service) versionLoop(ctx context.Context) {
	s.maybeVersion(ctx)
	ticker := time.NewTicker(time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.maybeVersion(ctx)
		}
	}
}

func (s *Service) maybeVersion(ctx context.Context) {
	if !s.cfg.AutoVersionCheck || len(s.pollable()) == 0 {
		return
	}
	s.mu.Lock()
	if s.checking {
		s.mu.Unlock()
		return
	}
	now := time.Now()
	if !s.retryAt.IsZero() && now.Before(s.retryAt) && (s.lastCheck.IsZero() || now.Sub(s.lastCheck) >= version.AutoInterval) {
		s.mu.Unlock()
		return
	}
	if !s.lastCheck.IsZero() && now.Sub(s.lastCheck) < version.AutoInterval {
		s.mu.Unlock()
		return
	}
	s.retryAt = now.Add(version.AutoRetryInterval)
	s.mu.Unlock()
	s.checkVersions(ctx, true)
}

func (s *Service) checkVersions(ctx context.Context, automatic bool) {
	s.mu.Lock()
	if s.checking || s.demo {
		s.mu.Unlock()
		return
	}
	s.checking = true
	var previous *version.Report
	if s.report != nil {
		copy := *s.report
		previous = &copy
	}
	s.mu.Unlock()

	checker := version.Checker{Make: s.provider, HTTP: s.client, Now: time.Now}
	report := checker.Run(ctx, s.pollable())

	s.mu.Lock()
	defer s.mu.Unlock()
	s.checking = false
	if automatic && report.FailedCompletely() {
		slog.Warn("automatic version check failed, retrying in an hour")
		return
	}
	s.report = &report
	s.lastCheck = report.CheckedAt
	s.retryAt = time.Time{}
	if automatic {
		s.unseen = map[string]bool{}
		for _, finding := range report.NewVulnerabilities(previous) {
			s.unseen[finding.RepoID+"|"+finding.Vuln.Key()] = true
		}
	}
	s.saveVersionsLocked()
}

func (s *Service) refreshRepo(ctx context.Context, accountID, repo string) {
	account, ok := s.account(accountID)
	if !ok || s.demo {
		return
	}
	s.mu.Lock()
	if s.checking {
		s.mu.Unlock()
		return
	}
	s.checking = true
	s.mu.Unlock()

	checker := version.Checker{Make: s.provider, HTTP: s.client, Now: time.Now}
	one := checker.RunRepo(ctx, account, repo)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.checking = false
	if s.report == nil {
		report := version.NewReport(time.Now(), []version.Repo{one})
		s.report = &report
	} else {
		next := s.report.Replacing(one)
		s.report = &next
	}
	s.saveVersionsLocked()
}

func (s *Service) saveVersionsLocked() {
	var keys []string
	for key := range s.unseen {
		keys = append(keys, key)
	}
	if err := s.store.SaveVersions(store.VersionsFile{Report: s.report, Unseen: keys}); err != nil {
		slog.Error("save versions", "err", err)
	}
}

func (s *Service) provider(account model.Account) provider.Source {
	token := func(context.Context) (string, error) {
		v := strings.TrimSpace(os.Getenv(account.TokenEnv))
		if v == "" {
			return "", provider.MissingToken()
		}
		return v, nil
	}
	switch account.Kind {
	case model.ProviderGitHub:
		return &github.Client{AccountID: account.ID, Owner: account.Organization, Token: token, HTTP: s.client}
	default:
		auth := account.AzureAuth
		if auth == "" {
			auth = "pat"
		}
		return &azure.Client{
			AccountID:    account.ID,
			Organization: account.Organization,
			Auth:         auth,
			Token:        token,
			HTTP:         s.client,
		}
	}
}

func (s *Service) pollable() []model.Account {
	var out []model.Account
	for _, account := range s.cfg.Accounts {
		if account.Pollable() {
			out = append(out, account)
		}
	}
	return out
}

func (s *Service) account(id string) (model.Account, bool) {
	for _, account := range s.cfg.Accounts {
		if account.ID == id {
			return account, true
		}
	}
	return model.Account{}, false
}

func (s *Service) page(section, query, kind string) web.Page {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	page := web.Page{
		Section:  section,
		Unseen:   s.hist.UnreadCount(),
		NewCVEs:  len(s.unseen),
		Demo:     s.demo,
		Checking: s.checking,
		Query:    query,
		Kind:     kind,
	}
	names := map[string]string{}
	statuses := map[string]poll.State{}
	if s.engine != nil {
		statuses = s.engine.Statuses()
	}
	for _, account := range s.cfg.Accounts {
		names[account.ID] = account.DisplayName
		st := statuses[account.ID]
		row := web.Account{Name: account.DisplayName, Kind: kindLabel(account.Kind)}
		switch {
		case s.demo:
			row.OK = true
			row.Detail = "Sample data"
		case st.Kind == "ok":
			row.OK = true
			row.Detail = "Polled " + web.RelTime(st.LastPoll, now)
		case st.Kind == "failed":
			row.Bad = true
			row.Detail = st.Message
		default:
			row.Detail = "Waiting for the first poll"
		}
		page.Accounts = append(page.Accounts, row)
	}
	var items []history.Item
	switch section {
	case "history":
		page.EmptyHistory = len(s.hist.Items) == 0
		items = s.hist.Search(query, history.Kind(kind))
	default:
		items = s.hist.Unread()
	}
	next := "/"
	if section == "history" {
		next = "/history"
	}
	for _, it := range items {
		row := s.itemRow(it, names, now)
		row.Next = next
		page.Items = append(page.Items, row)
	}
	if s.report != nil {
		page.CheckedAt = web.RelTime(s.report.CheckedAt, now)
		for _, repo := range s.report.Repos {
			page.Repos = append(page.Repos, s.repoRow(repo))
		}
	}
	return page
}

func (s *Service) itemRow(it history.Item, names map[string]string, now time.Time) web.Item {
	kind := "PR"
	state := ""
	if it.Entry.Kind == history.KindTag {
		kind = "tag"
	} else if it.Entry.PRState() == model.PRMerged {
		kind = "merged"
		state = "merged"
	} else if it.Entry.PRState() != "" {
		state = string(it.Entry.PRState())
	}
	draft := false
	if it.Entry.PullRequest != nil {
		draft = it.Entry.PullRequest.IsDraft
	}
	return web.Item{
		ID:      it.ID(),
		Kind:    kind,
		Repo:    it.Entry.Repo(),
		Title:   it.Entry.Title(),
		Author:  it.Entry.Author(),
		When:    web.RelTime(it.DetectedAt, now),
		URL:     it.Entry.WebURL(),
		State:   state,
		Account: names[it.Entry.AccountID()],
		Unread:  !it.IsRead,
		Draft:   draft,
	}
}

func (s *Service) repoRow(repo version.Repo) web.Repo {
	row := web.Repo{
		ID:        repo.ID(),
		AccountID: repo.AccountID,
		Name:      repo.Repo,
		Error:     repo.Error,
		VulnError: repo.VulnerabilityError,
	}
	if st := repo.WorstStatus(); st != nil {
		row.Status = string(*st)
		row.StatusText = st.Label()
	}
	if len(repo.Vulnerabilities) > 0 && repo.Severity() >= 3 && (row.StatusText == "" || row.StatusText == "Current" || row.StatusText == "Behind" || row.StatusText == "Unknown") {
		row.Status = "eol"
		row.StatusText = "Vulnerable"
	}
	if repo.Release != nil {
		row.Release = repo.Release.Tag
	}
	for _, c := range repo.Components {
		latest := ""
		if c.Latest != "" && c.Latest != c.Version {
			latest = c.Latest
		}
		row.Components = append(row.Components, web.Component{
			Label:   c.Label,
			Version: c.Version,
			Latest:  latest,
			Status:  string(c.Status),
			Text:    c.Status.Label(),
			Sources: strings.Join(c.Sources, ", "),
		})
	}
	row.Nothing = repo.Error == "" && len(repo.Components) == 0
	var text strings.Builder
	text.WriteString(repo.Repo + "\n")
	for _, c := range row.Components {
		text.WriteString(c.Label + " " + c.Version)
		if c.Latest != "" {
			text.WriteString(" → " + c.Latest)
		}
		text.WriteString(" (" + c.Text + ")\n")
	}
	for _, v := range repo.Vulnerabilities {
		inRelease := ""
		if flag := repo.InRelease(v); flag != nil {
			if *flag {
				inRelease = "also in " + row.Release
			} else if row.Release != "" {
				inRelease = "only on the default branch"
			}
		}
		row.Vulns = append(row.Vulns, web.Vuln{
			ID: v.ID, CVE: v.CVE, Summary: v.Summary, Severity: v.Severity,
			Package: v.Package, Version: v.Version, Fixed: v.FixedIn, Source: v.Source,
			URL: v.URL(), InRelease: inRelease, New: s.unseen[repo.ID()+"|"+v.Key()],
		})
		label := v.ID
		if v.CVE != "" {
			label = v.CVE
		}
		text.WriteString(label + " " + v.Package + " " + v.Version)
		if v.FixedIn != "" {
			text.WriteString(" → " + v.FixedIn)
		}
		text.WriteString("\n")
	}
	row.Text = text.String()
	return row
}

func kindLabel(kind model.ProviderKind) string {
	if kind == model.ProviderAzureDevOps {
		return "Azure DevOps"
	}
	return "GitHub"
}
