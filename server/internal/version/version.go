// Package version scans followed repositories and compares them with
// endoflife.date and osv.dev, including the newest release tag.
package version

import (
	"context"
	"sort"
	"strings"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/detect"
	"github.com/alessandro823/pullwatch/server/internal/eol"
	"github.com/alessandro823/pullwatch/server/internal/model"
	"github.com/alessandro823/pullwatch/server/internal/osv"
	"github.com/alessandro823/pullwatch/server/internal/provider"
	"github.com/alessandro823/pullwatch/server/internal/semver"
)

const (
	AutoInterval      = 24 * time.Hour
	AutoRetryInterval = time.Hour
)

// Component is one language, runtime, framework or base image.
type Component struct {
	Product string     `json:"product"`
	Label   string     `json:"label"`
	Version string     `json:"version"`
	Latest  string     `json:"latest,omitempty"`
	Status  eol.Status `json:"status"`
	Sources []string   `json:"sources"`
}

// Release is the same check against the newest version tag.
type Release struct {
	Tag             string              `json:"tag"`
	Components      []Component         `json:"components"`
	Vulnerabilities []osv.Vulnerability `json:"vulnerabilities"`
	Error           string              `json:"error,omitempty"`
}

// Repo is the result for one repository. Status, sorting and "new CVE"
// tracking use the default branch. The release is extra context.
type Repo struct {
	AccountID          string              `json:"account_id"`
	Repo               string              `json:"repo"`
	Components         []Component         `json:"components"`
	Error              string              `json:"error,omitempty"`
	Vulnerabilities    []osv.Vulnerability `json:"vulnerabilities"`
	VulnerabilityError string              `json:"vulnerability_error,omitempty"`
	Release            *Release            `json:"release,omitempty"`
}

func (r Repo) ID() string { return r.AccountID + "/" + r.Repo }

func (r Repo) WorstStatus() *eol.Status {
	if r.Error != "" {
		s := eol.Unknown
		return &s
	}
	if len(r.Components) == 0 {
		return nil
	}
	best := r.Components[0].Status
	for _, c := range r.Components[1:] {
		if c.Status.Severity() > best.Severity() {
			best = c.Status
		}
	}
	return &best
}

// Severity ranks a vulnerability as heavily as EOL.
func (r Repo) Severity() int {
	worst := -1
	if s := r.WorstStatus(); s != nil {
		worst = s.Severity()
	}
	if len(r.Vulnerabilities) > 0 && eol.EOL.Severity() > worst {
		worst = eol.EOL.Severity()
	}
	return worst
}

// InRelease reports whether a default-branch vulnerability is also in the
// newest tag. The result is nil when there is no usable release scan.
func (r Repo) InRelease(v osv.Vulnerability) *bool {
	if r.Release == nil || r.Release.Error != "" {
		return nil
	}
	found := false
	for _, other := range r.Release.Vulnerabilities {
		if other.Key() == v.Key() {
			found = true
			break
		}
	}
	return &found
}

// Report is one full check.
type Report struct {
	CheckedAt time.Time `json:"checked_at"`
	Repos     []Repo    `json:"repos"`
}

func NewReport(checkedAt time.Time, repos []Repo) Report {
	sorted := append([]Repo(nil), repos...)
	sort.SliceStable(sorted, func(i, j int) bool {
		if sorted[i].Severity() != sorted[j].Severity() {
			return sorted[i].Severity() > sorted[j].Severity()
		}
		if len(sorted[i].Vulnerabilities) != len(sorted[j].Vulnerabilities) {
			return len(sorted[i].Vulnerabilities) > len(sorted[j].Vulnerabilities)
		}
		return strings.ToLower(sorted[i].Repo) < strings.ToLower(sorted[j].Repo)
	})
	return Report{CheckedAt: checkedAt, Repos: sorted}
}

func (r Report) Replacing(repo Repo) Report {
	repos := append([]Repo(nil), r.Repos...)
	for i := range repos {
		if repos[i].ID() == repo.ID() {
			repos[i] = repo
		}
	}
	return NewReport(r.CheckedAt, repos)
}

func (r Report) FailedCompletely() bool {
	if len(r.Repos) == 0 {
		return false
	}
	for _, repo := range r.Repos {
		if repo.Error == "" {
			return false
		}
	}
	return true
}

// Finding is a vulnerability that showed up for a repository.
type Finding struct {
	RepoID string
	Repo   string
	Vuln   osv.Vulnerability
}

// NewVulnerabilities are issues that were not present for that repository last
// time. Without a previous check, or when the previous scan failed, nothing
// is treated as new (that would be a flood of alerts).
func (r Report) NewVulnerabilities(previous *Report) []Finding {
	if previous == nil {
		return nil
	}
	before := map[string]Repo{}
	for _, repo := range previous.Repos {
		before[repo.ID()] = repo
	}
	var out []Finding
	for _, repo := range r.Repos {
		old, ok := before[repo.ID()]
		if !ok || old.Error != "" || old.VulnerabilityError != "" {
			continue
		}
		known := map[string]bool{}
		for _, v := range old.Vulnerabilities {
			known[v.Key()] = true
		}
		for _, v := range repo.Vulnerabilities {
			if !known[v.Key()] {
				out = append(out, Finding{RepoID: repo.ID(), Repo: repo.Repo, Vuln: v})
			}
		}
	}
	return out
}

// Checker scans accounts.
type Checker struct {
	Make func(model.Account) provider.Source
	HTTP provider.HTTPDoer
	Now  func() time.Time
}

// Run checks every followed repository (any of PRs, tags or completed).
func (c Checker) Run(ctx context.Context, accounts []model.Account) Report {
	now := c.Now()
	var targets []target
	var results []Repo
	for _, account := range accounts {
		src := c.Make(account)
		repos, err := src.ListRepos(ctx)
		if err != nil {
			results = append(results, Repo{AccountID: account.ID, Repo: account.DisplayName, Error: message(err)})
			continue
		}
		var followed []string
		for _, repo := range repos {
			w := account.Watch(repo)
			if w.PRs || w.Tags || w.Completed {
				followed = append(followed, repo)
			}
		}
		targets = append(targets, target{account: account, src: src, repos: followed})
	}
	results = append(results, c.check(ctx, targets, now)...)
	return NewReport(now, results)
}

// RunRepo rechecks a single repository.
func (c Checker) RunRepo(ctx context.Context, account model.Account, repo string) Repo {
	now := c.Now()
	results := c.check(ctx, []target{{account: account, src: c.Make(account), repos: []string{repo}}}, now)
	if len(results) == 0 {
		return Repo{AccountID: account.ID, Repo: repo}
	}
	return results[0]
}

type target struct {
	account model.Account
	src     provider.Source
	repos   []string
}

type scan struct {
	versions     []detect.Version
	dependencies []detect.Dependency
}

type repoScan struct {
	main    scan
	release *struct {
		tag   string
		scan  scan
		error string
	}
}

func (c Checker) check(ctx context.Context, targets []target, now time.Time) []Repo {
	type item struct {
		accountID string
		repo      string
		found     repoScan
		err       string
	}
	var scanned []item
	// Accounts in parallel, repositories of one account one after another.
	type batch struct {
		items []item
	}
	ch := make(chan batch, len(targets))
	if len(targets) == 0 {
		return nil
	}
	for _, t := range targets {
		t := t
		go func() {
			var items []item
			for _, repo := range t.repos {
				rs, err := scanWithRelease(ctx, repo, t.src)
				if err != nil {
					items = append(items, item{accountID: t.account.ID, repo: repo, err: message(err)})
					continue
				}
				items = append(items, item{accountID: t.account.ID, repo: repo, found: rs})
			}
			ch <- batch{items}
		}()
	}
	for i := 0; i < len(targets); i++ {
		b := <-ch
		scanned = append(scanned, b.items...)
	}

	var scans []scan
	for _, it := range scanned {
		if it.err != "" {
			continue
		}
		scans = append(scans, it.found.main)
		if it.found.release != nil && it.found.release.error == "" {
			scans = append(scans, it.found.release.scan)
		}
	}
	products := map[string]bool{}
	for _, s := range scans {
		for _, v := range s.versions {
			products[v.Product] = true
		}
	}
	releases := map[string][]eol.Release{}
	relCh := make(chan struct {
		product string
		rels    []eol.Release
		ok      bool
	}, len(products))
	for product := range products {
		product := product
		go func() {
			rels, err := eol.Fetch(ctx, product, c.HTTP, now)
			relCh <- struct {
				product string
				rels    []eol.Release
				ok      bool
			}{product, rels, err == nil}
		}()
	}
	for i := 0; i < len(products); i++ {
		r := <-relCh
		if r.ok {
			releases[r.product] = r.rels
		}
	}

	unique := map[detect.Dependency]struct{}{}
	var deps []detect.Dependency
	for _, s := range scans {
		for _, d := range s.dependencies {
			key := d.WithoutSource()
			if _, ok := unique[key]; ok {
				continue
			}
			unique[key] = struct{}{}
			deps = append(deps, key)
		}
	}
	vulnIDs := map[detect.Dependency][]string{}
	var osvError string
	records := map[string]osv.Record{}
	if len(deps) > 0 {
		ids, err := osv.Query(ctx, deps, c.HTTP, now)
		if err != nil {
			osvError = "CVE check failed: " + message(err)
		} else {
			for i, d := range deps {
				vulnIDs[d] = ids[i]
			}
			var all []string
			seenID := map[string]bool{}
			for _, list := range ids {
				for _, id := range list {
					if !seenID[id] {
						seenID[id] = true
						all = append(all, id)
					}
				}
			}
			sort.Strings(all)
			records = osv.Records(ctx, all, c.HTTP, now)
		}
	}

	componentsOf := func(s scan) []Component {
		combined := combine(s.versions)
		out := make([]Component, 0, len(combined))
		for _, item := range combined {
			status, latest := eol.Unknown, ""
			if rels, ok := releases[item.version.Product]; ok {
				status, latest = eol.Evaluate(item.version.Version, rels, now)
			}
			out = append(out, Component{
				Product: item.version.Product,
				Label:   item.version.Label,
				Version: item.version.Version,
				Latest:  latest,
				Status:  status,
				Sources: item.sources,
			})
		}
		return out
	}
	vulnsOf := func(s scan) []osv.Vulnerability {
		ids := make([][]string, len(s.dependencies))
		for i, d := range s.dependencies {
			ids[i] = vulnIDs[d.WithoutSource()]
		}
		return osv.Vulnerabilities(s.dependencies, ids, records)
	}

	var results []Repo
	for _, it := range scanned {
		if it.err != "" {
			results = append(results, Repo{AccountID: it.accountID, Repo: it.repo, Error: it.err})
			continue
		}
		var rel *Release
		if it.found.release != nil {
			rel = &Release{Tag: it.found.release.tag, Error: it.found.release.error}
			if it.found.release.error == "" {
				rel.Components = componentsOf(it.found.release.scan)
				rel.Vulnerabilities = vulnsOf(it.found.release.scan)
			}
		}
		verr := ""
		if len(it.found.main.dependencies) > 0 {
			verr = osvError
		}
		results = append(results, Repo{
			AccountID:          it.accountID,
			Repo:               it.repo,
			Components:         componentsOf(it.found.main),
			Vulnerabilities:    vulnsOf(it.found.main),
			VulnerabilityError: verr,
			Release:            rel,
		})
	}
	return results
}

func scanWithRelease(ctx context.Context, repo string, src provider.Source) (repoScan, error) {
	main, err := scanRef(ctx, repo, "", src)
	if err != nil {
		return repoScan{}, err
	}
	result := repoScan{main: main}
	fetch, err := src.Tags(ctx, []string{repo})
	if err != nil {
		return result, nil
	}
	var names []string
	for _, tag := range fetch.Tags {
		if tag.Repo == repo {
			names = append(names, tag.Name)
		}
	}
	tag := LatestTag(names)
	if tag == "" {
		return result, nil
	}
	sc, err := scanRef(ctx, repo, tag, src)
	result.release = &struct {
		tag   string
		scan  scan
		error string
	}{tag: tag}
	if err != nil {
		result.release.error = message(err)
		return result, nil
	}
	result.release.scan = sc
	return result, nil
}

func scanRef(ctx context.Context, repo, ref string, src provider.Source) (scan, error) {
	paths, err := src.FilePaths(ctx, repo, ref)
	if err != nil {
		return scan{}, err
	}
	var relevant []string
	for _, p := range paths {
		if detect.Relevant(p) || (detect.DepRelevant(p) && !detect.Ignored(p)) {
			relevant = append(relevant, p)
		}
		if len(relevant) >= detect.MaxFiles {
			break
		}
	}
	var s scan
	replaced := map[string]bool{}
	for _, p := range relevant {
		content, err := src.FileContent(ctx, repo, p, ref)
		if err != nil {
			continue
		}
		s.versions = append(s.versions, detect.Detect(p, content)...)
		if strings.HasSuffix(p, "go.mod") {
			for _, dir := range detect.LocalGoReplacements(p, content) {
				replaced[dir] = true
			}
		}
		if detect.DepRelevant(p) {
			for _, dep := range detect.Dependencies(p, content) {
				if !hasDep(s.dependencies, dep.WithoutSource()) {
					s.dependencies = append(s.dependencies, dep)
				}
			}
		}
	}
	var kept []detect.Version
	for _, v := range s.versions {
		if v.Product == "go" && replaced[parentDir(v.Source)] {
			continue
		}
		kept = append(kept, v)
	}
	s.versions = kept
	pinned := map[string]bool{}
	for _, v := range s.versions {
		if !v.IsMinimum {
			pinned[v.Product] = true
		}
	}
	kept = nil
	for _, v := range s.versions {
		if v.IsMinimum && pinned[v.Product] {
			continue
		}
		kept = append(kept, v)
	}
	s.versions = kept
	for i, v := range s.versions {
		names := detect.LockedPackages[v.Product]
		if len(names) == 0 {
			continue
		}
		for _, dep := range s.dependencies {
			if names[dep.Name] {
				s.versions[i].Version = dep.Version
				s.versions[i].Source = dep.Source
				s.versions[i].IsMinimum = false
				break
			}
		}
	}
	return s, nil
}

type combined struct {
	version detect.Version
	sources []string
}

func combine(found []detect.Version) []combined {
	var order []string
	oldest := map[string]detect.Version{}
	sources := map[string][]string{}
	for _, item := range found {
		if _, ok := oldest[item.Label]; !ok {
			order = append(order, item.Label)
			oldest[item.Label] = item
		} else if semver.Older(item.Version, oldest[item.Label].Version) {
			oldest[item.Label] = item
		}
		if !contains(sources[item.Label], item.Source) {
			sources[item.Label] = append(sources[item.Label], item.Source)
		}
	}
	out := make([]combined, 0, len(order))
	for _, label := range order {
		out = append(out, combined{oldest[label], sources[label]})
	}
	return out
}

// LatestTag is the tag with the highest version. Pre-releases count only when
// nothing else is versioned. Tags without a number are ignored.
func LatestTag(names []string) string {
	type item struct{ name, version string }
	var versioned []item
	for _, name := range names {
		if v, ok := semver.From(name); ok {
			versioned = append(versioned, item{name, v})
		}
	}
	isPre := func(name string) bool {
		i := strings.IndexFunc(name, func(r rune) bool { return r >= '0' && r <= '9' })
		if i < 0 {
			return false
		}
		rest := strings.ToLower(name[i:])
		for _, needle := range []string{"-", "alpha", "beta", "rc", "pre", "preview"} {
			if strings.Contains(rest, needle) {
				return true
			}
		}
		return false
	}
	var finals []item
	for _, it := range versioned {
		if !isPre(it.name) {
			finals = append(finals, it)
		}
	}
	candidates := finals
	if len(candidates) == 0 {
		candidates = versioned
	}
	if len(candidates) == 0 {
		return ""
	}
	best := candidates[0]
	for _, it := range candidates[1:] {
		newer := semver.Older(best.version, it.version) ||
			(!semver.Older(it.version, best.version) && semver.NumericCompare(best.name, it.name) < 0)
		if newer {
			best = it
		}
	}
	return best.name
}

func message(err error) string {
	if pe, ok := provider.AsError(err); ok {
		return pe.UserMessage()
	}
	if err == nil {
		return ""
	}
	return err.Error()
}

func hasDep(deps []detect.Dependency, key detect.Dependency) bool {
	for _, d := range deps {
		if d.WithoutSource() == key {
			return true
		}
	}
	return false
}

func parentDir(p string) string {
	i := strings.LastIndexByte(p, '/')
	if i < 0 {
		return ""
	}
	return p[:i]
}

func contains(ss []string, v string) bool {
	for _, s := range ss {
		if s == v {
			return true
		}
	}
	return false
}
