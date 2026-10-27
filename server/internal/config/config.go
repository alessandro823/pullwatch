// Package config loads the server configuration from a YAML file and the environment.
// Tokens are read from environment variables and are never written back.
package config

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/history"
	"github.com/alessandro823/pullwatch/server/internal/model"
	"gopkg.in/yaml.v3"
)

const (
	minInterval = 60 * time.Second
	maxInterval = 900 * time.Second
)

// Config is everything the process needs except secret values.
type Config struct {
	Listen            string
	DataDir           string
	PollInterval      time.Duration
	HistoryRetention  history.Retention
	AutoVersionCheck  bool
	DashboardUser     string
	DashboardPassword string
	Accounts          []model.Account
}

type file struct {
	Listen           string        `yaml:"listen"`
	DataDir          string        `yaml:"data_dir"`
	PollInterval     string        `yaml:"poll_interval"`
	HistoryRetention string        `yaml:"history_retention"`
	AutoVersionCheck *bool         `yaml:"auto_version_check"`
	Accounts         []accountFile `yaml:"accounts"`
}

type accountFile struct {
	ID             string               `yaml:"id"`
	Name           string               `yaml:"name"`
	Provider       string               `yaml:"provider"`
	Organization   string               `yaml:"organization"`
	TokenEnv       string               `yaml:"token_env"`
	Token          string               `yaml:"token"`
	Auth           string               `yaml:"auth"`
	IncludeDrafts  *bool                `yaml:"include_drafts"`
	HideOwn        *bool                `yaml:"hide_own"`
	NewRepoDefault string               `yaml:"new_repo_default"`
	Repos          map[string]watchFile `yaml:"repos"`
}

type watchFile struct {
	PRs             *bool `yaml:"prs"`
	Tags            *bool `yaml:"tags"`
	Completed       *bool `yaml:"completed"`
	NotifyPRs       *bool `yaml:"notify_prs"`
	NotifyTags      *bool `yaml:"notify_tags"`
	NotifyCompleted *bool `yaml:"notify_completed"`
}

// Load reads path and applies environment overrides.
// PULLWATCH_LISTEN, PULLWATCH_DATA_DIR, PULLWATCH_POLL_INTERVAL,
// PULLWATCH_DASHBOARD_USER and PULLWATCH_DASHBOARD_PASSWORD override the file.
func Load(path string) (Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	return Parse(raw)
}

// Parse decodes YAML. Token values are not read here; polling reads token_env
// from the process environment so a missing token can be shown on the dashboard.
func Parse(raw []byte) (Config, error) {
	var f file
	if err := yaml.Unmarshal(raw, &f); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	cfg := Config{
		Listen:           orDefault(f.Listen, ":8080"),
		DataDir:          orDefault(f.DataDir, "data"),
		HistoryRetention: history.Retention(orDefault(f.HistoryRetention, string(history.RetentionOneYear))),
		AutoVersionCheck: f.AutoVersionCheck == nil || *f.AutoVersionCheck,
	}
	switch cfg.HistoryRetention {
	case history.RetentionTwoMonths, history.RetentionSixMonths, history.RetentionOneYear, history.RetentionForever:
	default:
		return Config{}, fmt.Errorf("history_retention must be two_months, six_months, one_year or forever")
	}
	interval, err := parseInterval(f.PollInterval)
	if err != nil {
		return Config{}, err
	}
	cfg.PollInterval = clampInterval(interval)

	seenIDs := map[string]bool{}
	for i, af := range f.Accounts {
		if strings.TrimSpace(af.Token) != "" {
			return Config{}, fmt.Errorf("account %d: set %s in the environment, not token in the config file", i+1, suggestedEnv(af))
		}
		acc, err := af.toAccount()
		if err != nil {
			return Config{}, fmt.Errorf("account %d: %w", i+1, err)
		}
		if seenIDs[acc.ID] {
			return Config{}, fmt.Errorf("duplicate account id %q", acc.ID)
		}
		seenIDs[acc.ID] = true
		if acc.TokenEnv == "" {
			return Config{}, fmt.Errorf("account %q: token_env is empty", acc.ID)
		}
		cfg.Accounts = append(cfg.Accounts, acc)
	}
	cfg.applyEnv()
	return cfg, nil
}

func (a accountFile) toAccount() (model.Account, error) {
	kind := model.ProviderKind(strings.ToLower(strings.TrimSpace(a.Provider)))
	switch kind {
	case model.ProviderGitHub, model.ProviderAzureDevOps:
	default:
		return model.Account{}, fmt.Errorf("provider must be github or azuredevops")
	}
	id := strings.TrimSpace(a.ID)
	if id == "" {
		id = strings.TrimSpace(a.Name)
	}
	if id == "" {
		id = string(kind) + "-" + strings.TrimSpace(a.Organization)
	}
	if strings.TrimSpace(id) == "" {
		return model.Account{}, fmt.Errorf("id or organization is required")
	}
	def := model.NewRepoDefault(strings.TrimSpace(a.NewRepoDefault))
	if def == "" {
		def = model.DefaultPRs
	}
	if def != model.DefaultNone && def != model.DefaultPRs {
		return model.Account{}, fmt.Errorf("new_repo_default must be none or prs")
	}
	auth := strings.ToLower(strings.TrimSpace(a.Auth))
	if auth == "" {
		auth = "pat"
	}
	if kind == model.ProviderAzureDevOps && auth != "pat" && auth != "bearer" {
		return model.Account{}, fmt.Errorf("auth must be pat or bearer")
	}
	tokenEnv := strings.TrimSpace(a.TokenEnv)
	if tokenEnv == "" {
		if kind == model.ProviderGitHub {
			tokenEnv = "GITHUB_TOKEN"
		} else {
			tokenEnv = "AZURE_DEVOPS_TOKEN"
		}
	}
	watches := map[string]model.WatchSet{}
	for repo, w := range a.Repos {
		watches[repo] = w.toWatch()
	}
	hideOwn := true
	if a.HideOwn != nil {
		hideOwn = *a.HideOwn
	}
	includeDrafts := false
	if a.IncludeDrafts != nil {
		includeDrafts = *a.IncludeDrafts
	}
	name := strings.TrimSpace(a.Name)
	if name == "" {
		name = id
	}
	return model.Account{
		ID:             id,
		Kind:           kind,
		DisplayName:    name,
		Organization:   strings.TrimSpace(a.Organization),
		TokenEnv:       tokenEnv,
		AzureAuth:      auth,
		RepoWatch:      watches,
		NewRepoDefault: def,
		IncludeDrafts:  includeDrafts,
		HideOwn:        hideOwn,
	}, nil
}

func (w watchFile) toWatch() model.WatchSet {
	return model.WatchSet{
		PRs:             boolOr(w.PRs, false),
		Tags:            boolOr(w.Tags, false),
		Completed:       boolOr(w.Completed, false),
		NotifyPRs:       boolOr(w.NotifyPRs, true),
		NotifyTags:      boolOr(w.NotifyTags, true),
		NotifyCompleted: boolOr(w.NotifyCompleted, true),
	}
}

func (c *Config) applyEnv() {
	if v := strings.TrimSpace(os.Getenv("PULLWATCH_LISTEN")); v != "" {
		c.Listen = v
	}
	if v := strings.TrimSpace(os.Getenv("PULLWATCH_DATA_DIR")); v != "" {
		c.DataDir = v
	}
	if v := strings.TrimSpace(os.Getenv("PULLWATCH_POLL_INTERVAL")); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			c.PollInterval = clampInterval(d)
		}
	}
	c.DashboardUser = os.Getenv("PULLWATCH_DASHBOARD_USER")
	c.DashboardPassword = os.Getenv("PULLWATCH_DASHBOARD_PASSWORD")
}

// Token returns the secret for account from the environment.
func Token(account model.Account) (string, error) {
	v := strings.TrimSpace(os.Getenv(account.TokenEnv))
	if v == "" {
		return "", fmt.Errorf("%w: %s", errMissingToken, account.TokenEnv)
	}
	return v, nil
}

var errMissingToken = fmt.Errorf("missing token")

func parseInterval(raw string) (time.Duration, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 2 * time.Minute, nil
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("poll_interval: %w", err)
	}
	if d <= 0 {
		return 0, fmt.Errorf("poll_interval must be positive")
	}
	return d, nil
}

func clampInterval(d time.Duration) time.Duration {
	if d < minInterval {
		return minInterval
	}
	if d > maxInterval {
		return maxInterval
	}
	return d
}

func orDefault(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return strings.TrimSpace(v)
}

func boolOr(v *bool, def bool) bool {
	if v == nil {
		return def
	}
	return *v
}

func suggestedEnv(a accountFile) string {
	if strings.TrimSpace(a.TokenEnv) != "" {
		return a.TokenEnv
	}
	if strings.EqualFold(a.Provider, "azuredevops") {
		return "AZURE_DEVOPS_TOKEN"
	}
	return "GITHUB_TOKEN"
}
