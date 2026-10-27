package store

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/history"
	"github.com/alessandro823/pullwatch/server/internal/model"
	"github.com/alessandro823/pullwatch/server/internal/seen"
	"github.com/alessandro823/pullwatch/server/internal/version"
)

func TestRoundTrip(t *testing.T) {
	dir := t.TempDir()
	s := Store{Dir: dir}
	state := seen.New()
	state.Mark("a:1", time.Unix(100, 0).UTC())
	if err := s.SaveSeen(state); err != nil {
		t.Fatal(err)
	}
	loaded, err := s.LoadSeen()
	if err != nil || !loaded.Contains("a:1") {
		t.Fatal(err, loaded)
	}
	var list history.List
	list.Add([]model.PullRequest{{
		AccountID: "a", Repo: "acme/api", Number: 1, Title: "Hi", CreatedAt: time.Unix(100, 0).UTC(), WebURL: "https://example.test",
	}}, nil, time.Unix(100, 0).UTC())
	if err := s.SaveHistory(list); err != nil {
		t.Fatal(err)
	}
	got, err := s.LoadHistory()
	if err != nil || len(got.Items) != 1 || got.Items[0].Entry.Title() != "Hi" {
		t.Fatal(err, got)
	}
	report := version.NewReport(time.Unix(50, 0).UTC(), nil)
	if err := s.SaveVersions(VersionsFile{Report: &report, Unseen: []string{"k"}}); err != nil {
		t.Fatal(err)
	}
	vf, err := s.LoadVersions()
	if err != nil || vf.Report == nil || len(vf.Unseen) != 1 {
		t.Fatal(err, vf)
	}
	if _, err := filepath.Glob(filepath.Join(dir, "*.tmp-*")); err != nil {
		t.Fatal(err)
	}
}

func TestMissingFilesAreEmpty(t *testing.T) {
	s := Store{Dir: t.TempDir()}
	if _, err := s.LoadHistory(); err != nil {
		t.Fatal(err)
	}
	if _, err := s.LoadVersions(); err != nil {
		t.Fatal(err)
	}
	state, err := s.LoadSeen()
	if err != nil || state.Seen == nil {
		t.Fatal(err)
	}
}
