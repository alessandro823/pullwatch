package osv

import (
	"testing"

	"github.com/alessandro823/pullwatch/server/internal/detect"
)

func TestDecodeAndDedupe(t *testing.T) {
	raw := []byte(`{
      "id":"GHSA-29mw-wpgm-hmr9","summary":"ReDoS in lodash","aliases":["CVE-2020-28500","GO-2024-1"],
      "database_specific":{"severity":"moderate"},
      "affected":[{"package":{"name":"lodash","ecosystem":"npm"},"ranges":[
        {"type":"ECOSYSTEM","events":[{"fixed":"4.17.21"},{"fixed":"4.18.0"}]},
        {"type":"GIT","events":[{"fixed":"abc"}]}
      ]}]
    }`)
	rec, err := DecodeRecord(raw)
	if err != nil {
		t.Fatal(err)
	}
	if rec.Severity != "MODERATE" || len(rec.Fixed["npm/lodash"]) != 2 {
		t.Fatalf("%+v", rec)
	}
	dep := detect.Dependency{Ecosystem: "npm", Name: "lodash", Version: "4.17.20", Source: "package-lock.json"}
	alias := rec
	alias.ID = "GO-2024-1"
	alias.Aliases = []string{"GHSA-29mw-wpgm-hmr9"}
	found := Vulnerabilities(
		[]detect.Dependency{dep},
		[][]string{{"GO-2024-1", "GHSA-29mw-wpgm-hmr9"}},
		map[string]Record{"GHSA-29mw-wpgm-hmr9": rec, "GO-2024-1": alias},
	)
	if len(found) != 1 || found[0].ID != "GHSA-29mw-wpgm-hmr9" || found[0].CVE != "CVE-2020-28500" || found[0].FixedIn != "4.17.21" {
		t.Fatalf("%+v", found)
	}
}

func TestFixedVersionMustBeNewer(t *testing.T) {
	dep := detect.Dependency{Ecosystem: "Go", Name: "example.com/a", Version: "1.2.0"}
	rec := Record{ID: "GO-1", Fixed: map[string][]string{"Go/example.com/a": {"1.0.0", "1.3.0"}}}
	found := Vulnerabilities([]detect.Dependency{dep}, [][]string{{"GO-1"}}, map[string]Record{"GO-1": rec})
	if len(found) != 1 || found[0].FixedIn != "1.3.0" {
		t.Fatalf("%+v", found)
	}
}
