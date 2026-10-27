package azure

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/alessandro823/pullwatch/server/internal/model"
	"github.com/alessandro823/pullwatch/server/internal/provider"
)

func TestPullRequestsUseBasicAuth(t *testing.T) {
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		switch {
		case strings.HasSuffix(r.URL.Path, "/_apis/connectionData"):
			w.Write([]byte(`{"authenticatedUser":{"id":"user-1","providerDisplayName":"Ada"}}`))
		case strings.HasSuffix(r.URL.Path, "/_apis/projects"):
			w.Write([]byte(`{"value":[{"name":"Proj"}]}`))
		case strings.HasSuffix(r.URL.Path, "/pullrequests"):
			w.Write([]byte(`{"value":[{
              "pullRequestId":9,"title":"Fix login","status":"completed","isDraft":false,
              "creationDate":"2026-10-01T10:00:00.1234567Z","closedDate":"2026-10-02T10:00:00Z",
              "createdBy":{"id":"user-2","displayName":"Bea"},
              "repository":{"name":"web","project":{"name":"Proj"}}
            }]}`))
		case strings.Contains(r.URL.Path, "/refs"):
			w.Write([]byte(`{"value":[{"name":"refs/tags/v2.0.0","creator":{"displayName":"Ada"}}]}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()
	client := &Client{
		AccountID: "ado", Organization: "contoso", Auth: "pat", base: srv.URL,
		Token: func(context.Context) (string, error) { return "pat-value", nil },
		HTTP:  srv.Client(),
	}
	name, err := client.TestConnection(context.Background())
	if err != nil || name != "Ada" {
		t.Fatal(err, name)
	}
	want := "Basic " + base64.StdEncoding.EncodeToString([]byte(":pat-value"))
	if auth != want {
		t.Fatalf("auth %s", auth)
	}
	prs, err := client.OpenPullRequests(context.Background())
	if err != nil || len(prs) != 1 || prs[0].State != model.PRMerged || prs[0].Repo != "Proj/web" || prs[0].AuthorName != "Bea" {
		t.Fatalf("%v %+v", err, prs)
	}
	fetch, err := client.Tags(context.Background(), []string{"Proj/web"})
	if err != nil || len(fetch.Tags) != 1 || fetch.Tags[0].Name != "v2.0.0" || !strings.Contains(fetch.Tags[0].WebURL, "version=GTv2.0.0") {
		t.Fatalf("%v %+v", err, fetch)
	}
}

func TestAnonymousConnectionIsUnauthorized(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"authenticatedUser":{"id":"` + anonymousUserID + `"}}`))
	}))
	defer srv.Close()
	client := &Client{
		Organization: "contoso", base: srv.URL,
		Token: func(context.Context) (string, error) { return "x", nil },
		HTTP:  srv.Client(),
	}
	_, err := client.CurrentUserID(context.Background())
	pe, ok := provider.AsError(err)
	if !ok || pe.Kind != provider.KindUnauthorized {
		t.Fatal(err)
	}
}
