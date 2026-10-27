package app

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func TestDemoPagesRender(t *testing.T) {
	svc := Demo(":0")
	for _, path := range []string{"/", "/history", "/versions", "/healthz"} {
		rec := httptest.NewRecorder()
		svc.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", path, rec.Code, rec.Body.String())
		}
	}
	body := get(t, svc, "/")
	for _, want := range []string{"Retry budget for the billing client", "v1.4.2", "Fix the login redirect loop", "acme", "contoso", "Sample data"} {
		if !strings.Contains(body, want) {
			t.Errorf("inbox missing %q", want)
		}
	}
	if strings.Contains(body, "Bump the design tokens") {
		t.Error("read history row leaked into the inbox")
	}
	history := get(t, svc, "/history?q=design&kind=pull_request")
	if !strings.Contains(history, "Bump the design tokens") {
		t.Fatal("history search missed a read pull request")
	}
	versions := get(t, svc, "/versions")
	for _, want := range []string{"CVE-2020-28500", "lodash", "EOL", "Vulnerable", "contoso/web", "new"} {
		if !strings.Contains(versions, want) {
			t.Errorf("versions missing %q", want)
		}
	}
}

func TestMarkSeenRemovesItFromInbox(t *testing.T) {
	svc := Demo(":0")
	body := get(t, svc, "/")
	if !strings.Contains(body, "v1.4.2") {
		t.Fatal("expected the sample tag")
	}
	form := url.Values{}
	form.Set("id", "gh-acme:acme/api:tag:v1.4.2")
	form.Set("next", "/")
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/seen", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	svc.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusSeeOther {
		t.Fatalf("seen: %d", rec.Code)
	}
	if strings.Contains(get(t, svc, "/"), "v1.4.2") {
		t.Fatal("tag still unseen")
	}
	if !strings.Contains(get(t, svc, "/history"), "v1.4.2") {
		t.Fatal("tag left history")
	}
}

func TestBasicAuth(t *testing.T) {
	svc := Demo(":0")
	svc.cfg.DashboardUser = "ada"
	svc.cfg.DashboardPassword = "secret"
	rec := httptest.NewRecorder()
	svc.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("got %d", rec.Code)
	}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.SetBasicAuth("ada", "secret")
	rec = httptest.NewRecorder()
	svc.routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("authed: %d %s", rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	svc.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("healthz should stay open, got %d", rec.Code)
	}
}

func get(t *testing.T, svc *Service, path string) string {
	t.Helper()
	rec := httptest.NewRecorder()
	svc.routes().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("%s: %d %s", path, rec.Code, rec.Body.String())
	}
	return rec.Body.String()
}
