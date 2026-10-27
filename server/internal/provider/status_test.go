package provider

import (
	"net/http"
	"testing"
	"time"
)

func TestCheckStatus(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	cases := []struct {
		name   string
		status int
		header map[string]string
		kind   string
	}{
		{"ok", 200, nil, ""},
		{"azure login page", 203, nil, KindUnauthorized},
		{"unauthorized", 401, nil, KindUnauthorized},
		{"forbidden without rate limit", 403, nil, KindUnauthorized},
		{"retry after", 429, map[string]string{"Retry-After": "30"}, KindRateLimited},
		{"github reset", 403, map[string]string{"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1700000100"}, KindRateLimited},
		{"server", 500, nil, KindServer},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := make(http.Header)
			for k, v := range tc.header {
				h.Set(k, v)
			}
			err := CheckStatus(&http.Response{StatusCode: tc.status, Header: h}, now)
			if tc.kind == "" {
				if err != nil {
					t.Fatal(err)
				}
				return
			}
			pe, ok := AsError(err)
			if !ok || pe.Kind != tc.kind {
				t.Fatalf("got %#v", err)
			}
			if tc.kind == KindRateLimited && tc.header["Retry-After"] == "30" && !pe.Until.Equal(now.Add(30*time.Second)) {
				t.Fatalf("until %s", pe.Until)
			}
		})
	}
}

func TestParseTimeDropsFractions(t *testing.T) {
	got, ok := ParseTime("2026-10-27T18:06:00.1234567Z")
	if !ok {
		t.Fatal("expected a timestamp")
	}
	want, _ := time.Parse(time.RFC3339, "2026-10-27T18:06:00Z")
	if !got.Equal(want) {
		t.Fatalf("got %s", got)
	}
	if _, ok := ParseTime("nope"); ok {
		t.Fatal("junk should not parse")
	}
}
