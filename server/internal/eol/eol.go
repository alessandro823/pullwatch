// Package eol compares a detected version with endoflife.date (and swift.org for Swift).
package eol

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/provider"
	"github.com/alessandro823/pullwatch/server/internal/semver"
)

// Status is how a version compares with the newest released cycle.
// Patches do not count: only a newer major or minor is "behind".
type Status string

const (
	Current Status = "current"
	Behind  Status = "behind"
	EOL     Status = "eol"
	Unknown Status = "unknown"
)

func (s Status) Severity() int {
	switch s {
	case EOL:
		return 3
	case Behind:
		return 2
	case Unknown:
		return 1
	default:
		return 0
	}
}

func (s Status) Label() string {
	switch s {
	case Current:
		return "Current"
	case Behind:
		return "Behind"
	case EOL:
		return "EOL"
	default:
		return "Unknown"
	}
}

// Release is one cycle on endoflife.date, for example Go "1.27" or .NET "8".
type Release struct {
	Name        string
	ReleaseDate string
	IsEOL       bool
	Latest      string
}

const endOfLifeURL = "https://endoflife.date/api/v1/products/"
const swiftURL = "https://www.swift.org/api/v1/install/releases.json"

// Fetch loads cycles for product. Swift comes from swift.org; it has no EOL policy.
func Fetch(ctx context.Context, product string, client provider.HTTPDoer, now time.Time) ([]Release, error) {
	if product == "swift" {
		return fetchSwift(ctx, client, now)
	}
	return fetchProduct(ctx, product, client, now)
}

func fetchProduct(ctx context.Context, product string, client provider.HTTPDoer, now time.Time) ([]Release, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endOfLifeURL+product, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	body, _, err := provider.Do(ctx, client, req, now)
	if err != nil {
		return nil, err
	}
	return Decode(body)
}

// Decode parses an endoflife.date v1 product response.
func Decode(data []byte) ([]Release, error) {
	var response struct {
		Result struct {
			Releases []struct {
				Name        string `json:"name"`
				ReleaseDate string `json:"releaseDate"`
				IsEOL       *bool  `json:"isEol"`
				Latest      *struct {
					Name string `json:"name"`
				} `json:"latest"`
			} `json:"releases"`
		} `json:"result"`
	}
	if err := json.Unmarshal(data, &response); err != nil {
		return nil, provider.Decoding(err.Error())
	}
	out := make([]Release, 0, len(response.Result.Releases))
	for _, r := range response.Result.Releases {
		rel := Release{Name: r.Name, ReleaseDate: r.ReleaseDate}
		if r.IsEOL != nil {
			rel.IsEOL = *r.IsEOL
		}
		if r.Latest != nil {
			rel.Latest = r.Latest.Name
		}
		out = append(out, rel)
	}
	return out, nil
}

func fetchSwift(ctx context.Context, client provider.HTTPDoer, now time.Time) ([]Release, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, swiftURL, nil)
	if err != nil {
		return nil, err
	}
	body, _, err := provider.Do(ctx, client, req, now)
	if err != nil {
		return nil, err
	}
	return DecodeSwift(body)
}

// DecodeSwift folds patch releases ("6.2.1") into cycles ("6.2").
// Swift is never marked EOL.
func DecodeSwift(data []byte) ([]Release, error) {
	var releases []struct {
		Name string `json:"name"`
		Date string `json:"date"`
	}
	if err := json.Unmarshal(data, &releases); err != nil {
		return nil, provider.Decoding(err.Error())
	}
	type cycle struct{ date, latest string }
	cycles := map[string]cycle{}
	var order []string
	for _, rel := range releases {
		parts := splitDot(rel.Name)
		if len(parts) < 2 {
			continue
		}
		name := parts[0] + "." + parts[1]
		if cur, ok := cycles[name]; ok {
			date := cur.date
			if rel.Date < date {
				date = rel.Date
			}
			latest := cur.latest
			if semver.Older(latest, rel.Name) {
				latest = rel.Name
			}
			cycles[name] = cycle{date, latest}
		} else {
			order = append(order, name)
			cycles[name] = cycle{rel.Date, rel.Name}
		}
	}
	out := make([]Release, 0, len(order))
	for _, name := range order {
		c := cycles[name]
		out = append(out, Release{Name: name, ReleaseDate: c.date, Latest: c.latest})
	}
	return out, nil
}

// Evaluate compares version with released cycles. A release dated after today
// does not count. The matching cycle is the longest name the version equals
// or extends ("1.25.3" matches "1.25", and "1" must not match "10").
func Evaluate(version string, releases []Release, now time.Time) (Status, string) {
	today := now.UTC().Format("2006-01-02")
	var released []Release
	for _, r := range releases {
		if r.ReleaseDate <= today {
			released = append(released, r)
		}
	}
	if len(released) == 0 {
		return Unknown, ""
	}
	newest := released[0]
	for _, r := range released[1:] {
		if r.ReleaseDate > newest.ReleaseDate {
			newest = r
		}
	}
	latest := newest.Latest
	if latest == "" {
		latest = newest.Name
	}
	var match *Release
	for i := range released {
		r := &released[i]
		if version == r.Name || stringsHasPrefixDot(version, r.Name) {
			if match == nil || len(r.Name) > len(match.Name) {
				match = r
			}
		}
	}
	if match == nil {
		return Unknown, latest
	}
	if match.IsEOL {
		return EOL, latest
	}
	if match.Name == newest.Name {
		return Current, latest
	}
	return Behind, latest
}

func stringsHasPrefixDot(version, name string) bool {
	return len(version) > len(name) && version[:len(name)] == name && version[len(name)] == '.'
}

func splitDot(s string) []string {
	var out []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '.' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}
