package config

import (
	"strings"
	"testing"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/history"
)

func TestParseRejectsInlineTokensAndDefaults(t *testing.T) {
	_, err := Parse([]byte(`
listen: ":9090"
accounts:
  - provider: github
    organization: acme
    token: super-secret
`))
	if err == nil || !strings.Contains(err.Error(), "environment") {
		t.Fatalf("inline token should be rejected, got %v", err)
	}

	cfg, err := Parse([]byte(`
poll_interval: 30s
accounts:
  - name: work
    provider: github
    organization: acme
  - provider: azuredevops
    organization: contoso
    auth: bearer
    hide_own: false
    new_repo_default: none
    repos:
      contoso/web:
        prs: true
        tags: true
`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PollInterval != time.Minute {
		t.Fatalf("interval clamped to %s", cfg.PollInterval)
	}
	if cfg.HistoryRetention != history.RetentionOneYear || !cfg.AutoVersionCheck {
		t.Fatalf("defaults: %+v", cfg)
	}
	gh := cfg.Accounts[0]
	if gh.TokenEnv != "GITHUB_TOKEN" || gh.ID != "work" || !gh.HideOwn || gh.NewRepoDefault != "prs" {
		t.Fatalf("github account: %+v", gh)
	}
	for _, account := range cfg.Accounts {
		if strings.Contains(account.DisplayName, "from-env") || account.TokenEnv == "from-env" {
			t.Fatal("token value must not be copied into the account")
		}
	}
	ado := cfg.Accounts[1]
	if ado.AzureAuth != "bearer" || ado.HideOwn || !ado.Watch("contoso/web").Tags || ado.Watch("other/repo").PRs {
		t.Fatalf("azure account: %+v watch=%+v", ado, ado.Watch("contoso/web"))
	}
}

func TestLongIntervalIsClamped(t *testing.T) {
	cfg, err := Parse([]byte("poll_interval: 2h\naccounts: []\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.PollInterval != 900*time.Second {
		t.Fatalf("got %s", cfg.PollInterval)
	}
}
