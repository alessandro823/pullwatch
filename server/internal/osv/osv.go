// Package osv looks up known vulnerabilities on osv.dev.
package osv

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/detect"
	"github.com/alessandro823/pullwatch/server/internal/provider"
	"github.com/alessandro823/pullwatch/server/internal/semver"
)

const (
	batchSize         = 1000
	detailConcurrency = 8
	queryURL          = "https://api.osv.dev/v1/querybatch"
	vulnURL           = "https://api.osv.dev/v1/vulns/"
)

// Vulnerability is one known issue in a package.
type Vulnerability struct {
	ID        string `json:"id"`
	CVE       string `json:"cve,omitempty"`
	Summary   string `json:"summary,omitempty"`
	Severity  string `json:"severity,omitempty"`
	Ecosystem string `json:"ecosystem"`
	Package   string `json:"package"`
	Version   string `json:"version"`
	FixedIn   string `json:"fixed_in,omitempty"`
	Source    string `json:"source"`
}

// Key identifies the same issue in the same package, regardless of version.
func (v Vulnerability) Key() string { return v.ID + "|" + v.Package }

func (v Vulnerability) URL() string { return "https://osv.dev/vulnerability/" + v.ID }

func (v Vulnerability) SeverityRank() int {
	switch v.Severity {
	case "CRITICAL":
		return 4
	case "HIGH":
		return 3
	case "MODERATE", "MEDIUM":
		return 2
	case "LOW":
		return 1
	default:
		return 0
	}
}

// Record is the slice of an OSV document the dashboard shows.
type Record struct {
	ID       string
	Aliases  []string
	Summary  string
	Severity string
	// Fixed maps "ecosystem/name" to versions that contain a fix.
	Fixed map[string][]string
}

type queryBody struct {
	Queries []queryItem `json:"queries"`
}

type queryItem struct {
	Package struct {
		Name      string `json:"name"`
		Ecosystem string `json:"ecosystem"`
	} `json:"package"`
	Version string `json:"version"`
}

// Query returns vulnerability ids per dependency, in the same order.
func Query(ctx context.Context, deps []detect.Dependency, client provider.HTTPDoer, now time.Time) ([][]string, error) {
	var ids [][]string
	for start := 0; start < len(deps); start += batchSize {
		end := start + batchSize
		if end > len(deps) {
			end = len(deps)
		}
		chunk := deps[start:end]
		body := queryBody{Queries: make([]queryItem, len(chunk))}
		for i, d := range chunk {
			body.Queries[i].Package.Name = d.Name
			body.Queries[i].Package.Ecosystem = d.Ecosystem
			body.Queries[i].Version = d.Version
		}
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, queryURL, bytes.NewReader(raw))
		if err != nil {
			return nil, err
		}
		req.Header.Set("Content-Type", "application/json")
		data, _, err := provider.Do(ctx, client, req, now)
		if err != nil {
			return nil, err
		}
		var resp struct {
			Results []struct {
				Vulns []struct {
					ID string `json:"id"`
				} `json:"vulns"`
			} `json:"results"`
		}
		if err := json.Unmarshal(data, &resp); err != nil {
			return nil, provider.Decoding(err.Error())
		}
		if len(resp.Results) != len(chunk) {
			return nil, provider.Decoding("OSV result count does not match the query")
		}
		for _, r := range resp.Results {
			var one []string
			for _, v := range r.Vulns {
				one = append(one, v.ID)
			}
			ids = append(ids, one)
		}
	}
	return ids, nil
}

// DecodeRecord parses one OSV vulnerability document.
func DecodeRecord(data []byte) (Record, error) {
	var raw struct {
		ID       string   `json:"id"`
		Aliases  []string `json:"aliases"`
		Summary  string   `json:"summary"`
		Database *struct {
			Severity string `json:"severity"`
		} `json:"database_specific"`
		Affected []struct {
			Package *struct {
				Name      string `json:"name"`
				Ecosystem string `json:"ecosystem"`
			} `json:"package"`
			Ranges []struct {
				Type   string `json:"type"`
				Events []struct {
					Fixed string `json:"fixed"`
				} `json:"events"`
			} `json:"ranges"`
		} `json:"affected"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return Record{}, provider.Decoding(err.Error())
	}
	rec := Record{ID: raw.ID, Aliases: raw.Aliases, Summary: raw.Summary, Fixed: map[string][]string{}}
	if raw.Database != nil {
		rec.Severity = strings.ToUpper(raw.Database.Severity)
	}
	for _, aff := range raw.Affected {
		if aff.Package == nil {
			continue
		}
		key := aff.Package.Ecosystem + "/" + aff.Package.Name
		for _, rg := range aff.Ranges {
			if strings.EqualFold(rg.Type, "GIT") {
				continue
			}
			for _, ev := range rg.Events {
				if ev.Fixed != "" {
					rec.Fixed[key] = append(rec.Fixed[key], ev.Fixed)
				}
			}
		}
	}
	return rec, nil
}

// Records fetches details, detailConcurrency at a time. Failed ids are omitted.
func Records(ctx context.Context, ids []string, client provider.HTTPDoer, now time.Time) map[string]Record {
	out := map[string]Record{}
	if len(ids) == 0 {
		return out
	}
	type result struct {
		rec Record
		ok  bool
	}
	jobs := make(chan string)
	results := make(chan result)
	workers := detailConcurrency
	if workers > len(ids) {
		workers = len(ids)
	}
	for i := 0; i < workers; i++ {
		go func() {
			for id := range jobs {
				rec, err := fetchRecord(ctx, id, client, now)
				if err != nil {
					results <- result{}
					continue
				}
				results <- result{rec: rec, ok: true}
			}
		}()
	}
	go func() {
		for _, id := range ids {
			jobs <- id
		}
		close(jobs)
	}()
	for i := 0; i < len(ids); i++ {
		r := <-results
		if r.ok {
			out[r.rec.ID] = r.rec
		}
	}
	return out
}

func fetchRecord(ctx context.Context, id string, client provider.HTTPDoer, now time.Time) (Record, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, vulnURL+id, nil)
	if err != nil {
		return Record{}, err
	}
	data, _, err := provider.Do(ctx, client, req, now)
	if err != nil {
		return Record{}, err
	}
	return DecodeRecord(data)
}

// Vulnerabilities joins query ids with records. When two ids are aliases of
// each other for the same package, the alphabetically first one is kept
// (a GHSA id wins over a GO id).
func Vulnerabilities(deps []detect.Dependency, ids [][]string, records map[string]Record) []Vulnerability {
	var result []Vulnerability
	for i, dep := range deps {
		if i >= len(ids) || len(ids[i]) == 0 {
			continue
		}
		found := append([]string(nil), ids[i]...)
		sort.Strings(found)
		var kept []string
		for _, id := range found {
			dup := false
			for _, other := range kept {
				if aliasOf(records, other, id) || aliasOf(records, id, other) {
					dup = true
					break
				}
			}
			if !dup {
				kept = append(kept, id)
			}
		}
		for _, id := range kept {
			rec, ok := records[id]
			var fixes []string
			if ok {
				fixes = rec.Fixed[dep.Ecosystem+"/"+dep.Name]
			}
			var fixedIn string
			for _, fix := range fixes {
				if !semver.Older(dep.Version, fix) {
					continue
				}
				if fixedIn == "" || semver.Older(fix, fixedIn) {
					fixedIn = fix
				}
			}
			cve := ""
			if ok {
				for _, alias := range rec.Aliases {
					if strings.HasPrefix(alias, "CVE-") {
						cve = alias
						break
					}
				}
			}
			if cve == "" && strings.HasPrefix(id, "CVE-") {
				cve = id
			}
			v := Vulnerability{
				ID: id, CVE: cve, Ecosystem: dep.Ecosystem, Package: dep.Name,
				Version: dep.Version, FixedIn: fixedIn, Source: dep.Source,
			}
			if ok {
				v.Summary = rec.Summary
				v.Severity = rec.Severity
			}
			result = append(result, v)
		}
	}
	sort.SliceStable(result, func(i, j int) bool {
		if result[i].SeverityRank() != result[j].SeverityRank() {
			return result[i].SeverityRank() > result[j].SeverityRank()
		}
		if result[i].Package != result[j].Package {
			return result[i].Package < result[j].Package
		}
		return result[i].ID < result[j].ID
	})
	return result
}

func aliasOf(records map[string]Record, id, other string) bool {
	rec, ok := records[id]
	if !ok {
		return false
	}
	for _, a := range rec.Aliases {
		if a == other {
			return true
		}
	}
	return false
}
