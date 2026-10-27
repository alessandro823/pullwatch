package github

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestOpenPullRequestsAndTags(t *testing.T) {
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		if r.Header.Get("X-GitHub-Api-Version") != apiVersion {
			t.Errorf("api version %s", r.Header.Get("X-GitHub-Api-Version"))
		}
		switch {
		case r.URL.Path == "/user":
			w.Write([]byte(`{"login":"ada"}`))
		case r.URL.Path == "/users/acme":
			w.Write([]byte(`{"type":"Organization"}`))
		case r.URL.Path == "/orgs/acme/repos":
			w.Write([]byte(`[{"full_name":"acme/api"}]`))
		case r.URL.Path == "/search/issues":
			if !strings.Contains(r.URL.Query().Get("q"), "org:acme") {
				t.Errorf("query %s", r.URL.RawQuery)
			}
			w.Write([]byte(`{"total_count":1,"items":[{
              "number":7,"title":"Add retries","created_at":"2026-10-27T18:06:00.1234567Z",
              "draft":false,"state":"open","user":{"login":"bea"},
              "html_url":"https://github.com/acme/api/pull/7",
              "repository_url":"https://api.github.com/repos/acme/api",
              "pull_request":{}
            }]}`))
		case r.URL.Path == "/repos/acme/api/tags":
			w.Write([]byte(`[{"name":"v1.2.0"},{"name":"v1.2.0+build"}]`))
		case r.URL.Path == "/repos/acme/missing/tags":
			w.WriteHeader(http.StatusNotFound)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	client := &Client{
		AccountID: "gh", Owner: "acme", base: srv.URL,
		Token: func(context.Context) (string, error) { return "tok", nil },
		HTTP:  srv.Client(), Now: func() time.Time { return time.Unix(0, 0) },
	}
	login, err := client.TestConnection(context.Background())
	if err != nil || login != "ada" {
		t.Fatal(err, login)
	}
	if auth != "Bearer tok" {
		t.Fatal(auth)
	}
	prs, err := client.OpenPullRequests(context.Background())
	if err != nil || len(prs) != 1 || prs[0].Repo != "acme/api" || prs[0].AuthorID != "bea" || prs[0].Number != 7 {
		t.Fatalf("%v %+v", err, prs)
	}
	fetch, err := client.Tags(context.Background(), []string{"acme/api", "acme/missing"})
	if err != nil || len(fetch.Tags) != 2 || len(fetch.UnavailableRepos) != 1 {
		t.Fatalf("%v %+v", err, fetch)
	}
	if !strings.Contains(fetch.Tags[1].WebURL, "v1.2.0%2Bbuild") {
		t.Fatal(fetch.Tags[1].WebURL)
	}
}

func TestUnauthorized(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()
	client := &Client{
		Owner: "acme", base: srv.URL,
		Token: func(context.Context) (string, error) { return "bad", nil },
		HTTP:  srv.Client(),
	}
	_, err := client.CurrentUserID(context.Background())
	if err == nil || !strings.Contains(err.Error(), "Token") {
		t.Fatal(err)
	}
}
