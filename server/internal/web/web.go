// Package web renders the dashboard. Assets are embedded; there is no frontend build.
package web

import (
	"embed"
	"html/template"
	"net/http"
	"strings"
	"time"
)

//go:embed assets/*.html
var assets embed.FS

// Page is one dashboard render.
type Page struct {
	Section       string
	Unseen        int
	NewCVEs       int
	Demo          bool
	Checking      bool
	Accounts      []Account
	Items         []Item
	Query         string
	Kind          string
	CheckedAt     string
	Repos         []Repo
	EmptyHistory  bool
	EmptyVersions bool
}

// Account is one source row.
type Account struct {
	Name   string
	Kind   string
	Status string
	Detail string
	OK     bool
	Bad    bool
}

// Item is a pull request or tag row.
type Item struct {
	ID      string
	Kind    string
	Repo    string
	Title   string
	Author  string
	When    string
	URL     string
	State   string
	Account string
	Unread  bool
	Draft   bool
	Next    string
}

// Repo is one repository in the version report.
type Repo struct {
	ID         string
	AccountID  string
	Name       string
	Status     string
	StatusText string
	Error      string
	VulnError  string
	Release    string
	Components []Component
	Vulns      []Vuln
	Text       string
	Nothing    bool
}

// Component is one detected language or framework.
type Component struct {
	Label   string
	Version string
	Latest  string
	Status  string
	Text    string
	Sources string
}

// Vuln is one OSV finding.
type Vuln struct {
	ID        string
	CVE       string
	Summary   string
	Severity  string
	Package   string
	Version   string
	Fixed     string
	Source    string
	URL       string
	InRelease string
	New       bool
}

var tmpl = template.Must(template.New("page").Funcs(template.FuncMap{
	"kindClass": func(kind string) string {
		switch kind {
		case "tag":
			return "tag"
		case "merged":
			return "merged"
		default:
			return "pr"
		}
	},
	"statusClass": func(status string) string {
		switch strings.ToLower(status) {
		case "current":
			return "current"
		case "behind":
			return "behind"
		case "eol":
			return "eol"
		case "critical", "high":
			return "eol"
		case "moderate", "medium":
			return "behind"
		case "low":
			return "unknown"
		default:
			return "unknown"
		}
	},
}).ParseFS(assets, "assets/*.html"))

// Render writes a page. name is inbox, history or versions.
func Render(w http.ResponseWriter, name string, page Page) error {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	page.Section = name
	return tmpl.ExecuteTemplate(w, name, page)
}

// RelTime formats t relative to now.
func RelTime(t, now time.Time) string {
	if t.IsZero() {
		return ""
	}
	d := now.Sub(t)
	future := d < 0
	if future {
		d = -d
	}
	var s string
	switch {
	case d < time.Minute:
		s = "just now"
		future = false
	case d < time.Hour:
		s = plural(int(d.Minutes()), "minute")
	case d < 24*time.Hour:
		s = plural(int(d.Hours()), "hour")
	case d < 14*24*time.Hour:
		s = plural(int(d.Hours()/24), "day")
	default:
		return t.Local().Format("2 Jan 2006")
	}
	if future {
		return "in " + s
	}
	if s == "just now" {
		return s
	}
	return s + " ago"
}

func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return itoa(n) + " " + word + "s"
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
