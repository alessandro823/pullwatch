package eol

import (
	"testing"
	"time"
)

func TestEvaluate(t *testing.T) {
	now := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	releases := []Release{
		{Name: "1.28", ReleaseDate: "2027-02-01", Latest: "1.28.0"},
		{Name: "1.27", ReleaseDate: "2026-08-19", Latest: "1.27.3"},
		{Name: "1.26", ReleaseDate: "2026-02-10", Latest: "1.26.10"},
		{Name: "1.25", ReleaseDate: "2025-08-12", IsEOL: true, Latest: "1.25.9"},
	}
	if status, latest := Evaluate("1.27.1", releases, now); status != Current || latest != "1.27.3" {
		t.Fatalf("current: %s %s", status, latest)
	}
	if status, latest := Evaluate("1.26", releases, now); status != Behind || latest != "1.27.3" {
		t.Fatalf("behind: %s %s", status, latest)
	}
	if status, _ := Evaluate("1.25.0", releases, now); status != EOL {
		t.Fatal(status)
	}
	if status, latest := Evaluate("2.0", releases, now); status != Unknown || latest != "1.27.3" {
		t.Fatalf("unknown: %s %s", status, latest)
	}
	dotnet := []Release{
		{Name: "10", ReleaseDate: "2025-11-11", Latest: "10.0.3"},
		{Name: "8", ReleaseDate: "2023-11-14", Latest: "8.0.20"},
	}
	if s, _ := Evaluate("8.0", dotnet, now); s != Behind {
		t.Fatal(s)
	}
	if s, _ := Evaluate("10.0", dotnet, now); s != Current {
		t.Fatal(s)
	}
	if s, _ := Evaluate("1.0", dotnet, now); s != Unknown {
		t.Fatal("1 must not match cycle 10")
	}
}

func TestDecodeAndSwiftCycles(t *testing.T) {
	releases, err := Decode([]byte(`{"result":{"releases":[{"name":"1.27","releaseDate":"2026-08-19","isEol":false,"latest":{"name":"1.27.3"}}]}}`))
	if err != nil || len(releases) != 1 || releases[0].Latest != "1.27.3" || releases[0].IsEOL {
		t.Fatal(err, releases)
	}
	swift, err := DecodeSwift([]byte(`[{"name":"6.2.1","date":"2026-04-01"},{"name":"6.2","date":"2026-01-01"},{"name":"6.0.3","date":"2025-09-01"}]`))
	if err != nil || len(swift) != 2 {
		t.Fatal(err, swift)
	}
	if swift[0].Name != "6.2" || swift[0].Latest != "6.2.1" || swift[0].ReleaseDate != "2026-01-01" || swift[0].IsEOL {
		t.Fatalf("%+v", swift[0])
	}
}
