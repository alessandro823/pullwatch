package seen

import (
	"testing"
	"time"
)

func TestPruneKeepsOtherAccountsAndDropsStale(t *testing.T) {
	s := New()
	now := time.Now()
	s.Mark("a:1", now.Add(-40*24*time.Hour))
	s.Mark("a:2", now)
	s.Mark("b:1", now.Add(-40*24*time.Hour))
	s.TagSeeded["a:repo"] = now.Add(-40 * 24 * time.Hour)
	s.Prune(now, []string{"a:"})
	if s.Contains("a:1") || s.TagSeeded["a:repo"] != (time.Time{}) {
		t.Fatal("stale entries for the polled account should go")
	}
	if !s.Contains("a:2") || !s.Contains("b:1") {
		t.Fatal("fresh keys and other accounts stay")
	}
	s.Retain([]string{"b:"})
	if s.Contains("a:2") || !s.Contains("b:1") {
		t.Fatal("retain keeps only the remaining accounts")
	}
}
