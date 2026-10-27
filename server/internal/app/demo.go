package app

import (
	"time"

	"github.com/alessandro823/pullwatch/server/internal/config"
	"github.com/alessandro823/pullwatch/server/internal/eol"
	"github.com/alessandro823/pullwatch/server/internal/history"
	"github.com/alessandro823/pullwatch/server/internal/model"
	"github.com/alessandro823/pullwatch/server/internal/osv"
	"github.com/alessandro823/pullwatch/server/internal/version"
)

// Demo serves a dashboard full of sample data and does not call GitHub or Azure DevOps.
func Demo(listen string) *Service {
	now := time.Now()
	gh := model.Account{
		ID: "gh-acme", Kind: model.ProviderGitHub, DisplayName: "acme", Organization: "acme",
		NewRepoDefault: model.DefaultPRs, HideOwn: true,
	}
	ado := model.Account{
		ID: "ado-contoso", Kind: model.ProviderAzureDevOps, DisplayName: "contoso", Organization: "contoso",
		NewRepoDefault: model.DefaultPRs, HideOwn: true,
	}
	closed := now.Add(-3 * time.Hour)
	hist := history.List{}
	hist.Add([]model.PullRequest{
		{
			AccountID: gh.ID, Repo: "acme/api", Number: 128, Title: "Retry budget for the billing client",
			AuthorName: "ada", CreatedAt: now.Add(-40 * time.Minute), WebURL: "https://github.com/acme/api/pull/128",
			State: model.PROpen,
		},
		{
			AccountID: ado.ID, Repo: "contoso/web", Number: 44, Title: "Fix the login redirect loop",
			AuthorName: "sam", CreatedAt: now.Add(-2 * time.Hour), WebURL: "https://dev.azure.com/contoso/web/_git/web/pullrequest/44",
			State: model.PROpen,
		},
	}, []model.Tag{
		{AccountID: gh.ID, Repo: "acme/api", Name: "v1.4.2", WebURL: "https://github.com/acme/api/releases/tag/v1.4.2"},
	}, now.Add(-8*time.Minute))
	hist.Add([]model.PullRequest{
		{
			AccountID: gh.ID, Repo: "acme/api", Number: 120, Title: "Ship the repository filter",
			AuthorName: "jo", CreatedAt: now.Add(-26 * time.Hour), WebURL: "https://github.com/acme/api/pull/120",
			State: model.PRMerged, ClosedAt: &closed,
		},
	}, nil, now.Add(-3*time.Hour))
	// An older read row, so history is more than the inbox.
	hist.Merge([]model.PullRequest{
		{
			AccountID: ado.ID, Repo: "contoso/web", Number: 41, Title: "Bump the design tokens",
			AuthorName: "mina", CreatedAt: now.Add(-10 * 24 * time.Hour),
			WebURL: "https://dev.azure.com/contoso/web/_git/web/pullrequest/41",
			State:  model.PRClosed, ClosedAt: &closed,
		},
	}, nil)

	behind := eol.Behind
	_ = behind
	report := version.NewReport(now.Add(-6*time.Hour), []version.Repo{
		{
			AccountID: gh.ID, Repo: "acme/api",
			Components: []version.Component{
				{Product: "go", Label: "Go", Version: "1.22.5", Latest: "1.25.3", Status: eol.Behind, Sources: []string{"go.mod"}},
				{Product: "nodejs", Label: "Docker node", Version: "20", Latest: "22.11.0", Status: eol.Behind, Sources: []string{"Dockerfile"}},
			},
			Vulnerabilities: []osv.Vulnerability{
				{
					ID: "GHSA-29mw-wpgm-hmr9", CVE: "CVE-2020-28500", Summary: "ReDoS in lodash",
					Severity: "MODERATE", Ecosystem: "npm", Package: "lodash", Version: "4.17.20",
					FixedIn: "4.17.21", Source: "package-lock.json",
				},
			},
			Release: &version.Release{Tag: "v1.4.2", Components: []version.Component{
				{Product: "go", Label: "Go", Version: "1.22.5", Latest: "1.25.3", Status: eol.Behind},
			}},
		},
		{
			AccountID: ado.ID, Repo: "contoso/legacy",
			Components: []version.Component{
				{Product: "dotnet", Label: ".NET", Version: "6.0", Latest: "8.0.20", Status: eol.EOL, Sources: []string{"src/Api/Api.csproj"}},
			},
		},
		{
			AccountID: ado.ID, Repo: "contoso/web",
			Components: []version.Component{
				{Product: "nodejs", Label: "Node", Version: "22.11.0", Latest: "22.11.0", Status: eol.Current, Sources: []string{".nvmrc"}},
				{Product: "angular", Label: "Angular", Version: "17.2.0", Latest: "19.0.0", Status: eol.Behind, Sources: []string{"package.json"}},
			},
		},
	})
	return &Service{
		cfg: config.Config{
			Listen:           listen,
			HistoryRetention: history.RetentionOneYear,
			Accounts:         []model.Account{gh, ado},
		},
		hist:   hist,
		report: &report,
		unseen: map[string]bool{
			"gh-acme/acme/api|GHSA-29mw-wpgm-hmr9|lodash": true,
		},
		demo: true,
	}
}
