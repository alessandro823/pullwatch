package version

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/eol"
	"github.com/alessandro823/pullwatch/server/internal/model"
	"github.com/alessandro823/pullwatch/server/internal/osv"
	"github.com/alessandro823/pullwatch/server/internal/provider"
)

func TestLatestTagSkipsPrereleases(t *testing.T) {
	if got := LatestTag([]string{"nightly", "v1.2.0-rc1", "v1.2.0", "v1.10.0", "v1.9.0"}); got != "v1.10.0" {
		t.Fatal(got)
	}
	if got := LatestTag([]string{"app-1.0.0-rc2", "app-1.0.0-rc10"}); got != "app-1.0.0-rc10" {
		t.Fatal(got)
	}
	if LatestTag([]string{"latest"}) != "" {
		t.Fatal("tags without a number do not count")
	}
}

func vuln(id, pkg string) osv.Vulnerability {
	return osv.Vulnerability{ID: id, Package: pkg, Ecosystem: "npm", Version: "1.0.0"}
}

func TestNewVulnerabilitiesSkipTheFirstCheck(t *testing.T) {
	old := NewReport(time.Now(), []Repo{{
		AccountID: "a", Repo: "acme/api",
		Vulnerabilities: []osv.Vulnerability{vuln("GHSA-1", "lodash")},
	}})
	next := NewReport(time.Now(), []Repo{{
		AccountID: "a", Repo: "acme/api",
		Vulnerabilities: []osv.Vulnerability{vuln("GHSA-1", "lodash"), vuln("GHSA-2", "left-pad")},
	}})
	found := next.NewVulnerabilities(&old)
	if len(found) != 1 || found[0].Vuln.ID != "GHSA-2" {
		t.Fatalf("%+v", found)
	}
	if len(next.NewVulnerabilities(nil)) != 0 {
		t.Fatal("no previous report means nothing is new")
	}
	failed := old
	failed.Repos[0].VulnerabilityError = "down"
	if len(next.NewVulnerabilities(&failed)) != 0 {
		t.Fatal("a failed previous CVE check does not flood")
	}
}

func TestReportOrdersBySeverity(t *testing.T) {
	report := NewReport(time.Unix(0, 0), []Repo{
		{AccountID: "a", Repo: "zeta", Components: []Component{{Status: eol.Current}}},
		{AccountID: "a", Repo: "alpha", Components: []Component{{Status: eol.EOL}}},
		{AccountID: "a", Repo: "mid", Components: []Component{{Status: eol.Behind}}},
	})
	if report.Repos[0].Repo != "alpha" || report.Repos[1].Repo != "mid" || report.Repos[2].Repo != "zeta" {
		t.Fatalf("%s %s %s", report.Repos[0].Repo, report.Repos[1].Repo, report.Repos[2].Repo)
	}
	if report.FailedCompletely() {
		t.Fatal("a useful report is not a total failure")
	}
	if !NewReport(time.Now(), []Repo{{Error: "x"}, {Error: "y"}}).FailedCompletely() {
		t.Fatal("every repo failing is a total failure")
	}
}

type memSource struct {
	repos []string
	tags  []string
	files map[string]string
}

func (m memSource) CurrentUserID(context.Context) (string, error) { return "ada", nil }
func (m memSource) ListRepos(context.Context) ([]string, error)   { return m.repos, nil }
func (m memSource) OpenPullRequests(context.Context) ([]model.PullRequest, error) {
	return nil, nil
}
func (m memSource) PullRequests(context.Context, *time.Time, int) ([]model.PullRequest, error) {
	return nil, nil
}
func (m memSource) Tags(context.Context, []string) (model.TagFetch, error) {
	var tags []model.Tag
	for _, name := range m.tags {
		tags = append(tags, model.Tag{Repo: m.repos[0], Name: name})
	}
	return model.TagFetch{Tags: tags}, nil
}
func (m memSource) FilePaths(context.Context, string, string) ([]string, error) {
	var paths []string
	for path := range m.files {
		paths = append(paths, path)
	}
	return paths, nil
}
func (m memSource) FileContent(_ context.Context, _, path, _ string) (string, error) {
	return m.files[path], nil
}
func (m memSource) Invalidate(context.Context) {}

type scriptHTTP struct{}

func (scriptHTTP) Do(req *http.Request) (*http.Response, error) {
	var body string
	switch {
	case strings.Contains(req.URL.Path, "/products/go"):
		body = `{"result":{"releases":[
          {"name":"1.25","releaseDate":"2025-08-12","isEol":false,"latest":{"name":"1.25.3"}},
          {"name":"1.22","releaseDate":"2024-02-06","isEol":true,"latest":{"name":"1.22.12"}}
        ]}}`
	case strings.HasSuffix(req.URL.Path, "/querybatch"):
		body = `{"results":[{"vulns":[{"id":"GO-1"}]}]}`
	case strings.Contains(req.URL.Path, "/vulns/GO-1"):
		body = `{"id":"GO-1","aliases":["CVE-2024-1"],"summary":"sample","database_specific":{"severity":"HIGH"},
          "affected":[{"package":{"ecosystem":"Go","name":"example.com/a"},"ranges":[{"type":"SEMVER","events":[{"fixed":"1.2.4"}]}]}]}`
	default:
		return &http.Response{StatusCode: 404, Body: io.NopCloser(strings.NewReader("missing")), Header: make(http.Header), Request: req}, nil
	}
	return &http.Response{
		StatusCode: 200,
		Body:       io.NopCloser(strings.NewReader(body)),
		Header:     make(http.Header),
		Request:    req,
	}, nil
}

func TestCheckerScansBranchAndRelease(t *testing.T) {
	account := model.Account{
		ID: "gh", Kind: model.ProviderGitHub, DisplayName: "acme", Organization: "acme",
		NewRepoDefault: model.DefaultPRs, HideOwn: true,
	}
	src := memSource{
		repos: []string{"acme/api"},
		tags:  []string{"v1.0.0-rc1", "v0.9.0"},
		files: map[string]string{
			"go.mod":          "module acme/api\n\ngo 1.22.0\n\nrequire example.com/a v1.2.3\n",
			"vendor/lib/skip": "nope",
		},
	}
	checker := Checker{
		Make: func(model.Account) provider.Source { return src },
		HTTP: scriptHTTP{},
		Now:  func() time.Time { return time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC) },
	}
	report := checker.Run(context.Background(), []model.Account{account})
	if len(report.Repos) != 1 {
		t.Fatalf("%+v", report.Repos)
	}
	repo := report.Repos[0]
	if len(repo.Components) != 1 || repo.Components[0].Version != "1.22.0" || repo.Components[0].Status != eol.EOL {
		t.Fatalf("component %+v", repo.Components)
	}
	if len(repo.Vulnerabilities) != 1 || repo.Vulnerabilities[0].CVE != "CVE-2024-1" || repo.Vulnerabilities[0].FixedIn != "1.2.4" {
		t.Fatalf("vuln %+v", repo.Vulnerabilities)
	}
	if repo.Release == nil || repo.Release.Tag != "v0.9.0" || repo.Release.Error != "" {
		t.Fatalf("release %+v", repo.Release)
	}
	in := repo.InRelease(repo.Vulnerabilities[0])
	if in == nil || !*in {
		t.Fatal("the same module is also in the release")
	}
}

func TestMinimumDropsWhenPinned(t *testing.T) {
	account := model.Account{ID: "gh", Organization: "acme", NewRepoDefault: model.DefaultPRs}
	src := memSource{
		repos: []string{"acme/api"},
		files: map[string]string{
			"package.json": `{"engines":{"node":">=20"}}`,
			"Dockerfile":   "FROM node:22-alpine\n",
		},
	}
	checker := Checker{
		Make: func(model.Account) provider.Source { return src },
		HTTP: scriptHTTP{},
		Now:  func() time.Time { return time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC) },
	}
	repo := checker.RunRepo(context.Background(), account, "acme/api")
	if len(repo.Components) != 1 || repo.Components[0].Version != "22" || repo.Components[0].Label != "Docker node" {
		t.Fatalf("pinned docker image should win: %+v", repo.Components)
	}
}
