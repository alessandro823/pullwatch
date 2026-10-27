// Package github talks to api.github.com for one owner (user or organisation).
package github

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/model"
	"github.com/alessandro823/pullwatch/server/internal/provider"
)

const (
	apiBase    = "https://api.github.com"
	pageSize   = 100
	maxPages   = 10
	apiAccept  = "application/vnd.github+json"
	apiVersion = "2022-11-28"
)

// Client is a GitHub account.
type Client struct {
	AccountID string
	Owner     string
	Token     func(context.Context) (string, error)
	HTTP      provider.HTTPDoer
	Now       func() time.Time
	base      string

	ownerKind string // "Organization" or "User"
}

func (c *Client) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c *Client) api() string {
	if c.base != "" {
		return c.base
	}
	return apiBase
}

func (c *Client) Invalidate(context.Context) { c.ownerKind = "" }

func (c *Client) CurrentUserID(ctx context.Context) (string, error) {
	var user struct {
		Login string `json:"login"`
	}
	if err := c.get(ctx, c.api()+"/user", nil, &user); err != nil {
		return "", err
	}
	return user.Login, nil
}

func (c *Client) TestConnection(ctx context.Context) (string, error) {
	login, err := c.CurrentUserID(ctx)
	if err != nil {
		return "", err
	}
	if _, err := c.resolveOwnerKind(ctx); err != nil {
		if pe, ok := provider.AsError(err); ok && pe.Kind == provider.KindServer && pe.Status == 404 {
			return "", provider.NoAccess(c.Owner)
		}
		return "", err
	}
	return login, nil
}

func (c *Client) ListRepos(ctx context.Context) ([]string, error) {
	kind, err := c.resolveOwnerKind(ctx)
	if err != nil {
		return nil, err
	}
	var endpoint string
	q := url.Values{}
	if kind == "Organization" {
		endpoint = c.api() + "/orgs/" + url.PathEscape(c.Owner) + "/repos"
	} else {
		login, err := c.CurrentUserID(ctx)
		if err != nil {
			return nil, err
		}
		if strings.EqualFold(login, c.Owner) {
			endpoint = c.api() + "/user/repos"
			q.Set("affiliation", "owner")
		} else {
			endpoint = c.api() + "/users/" + url.PathEscape(c.Owner) + "/repos"
		}
	}
	var names []string
	for page := 1; page <= maxPages; page++ {
		query := cloneValues(q)
		query.Set("per_page", fmt.Sprint(pageSize))
		query.Set("page", fmt.Sprint(page))
		var repos []struct {
			FullName string `json:"full_name"`
		}
		if err := c.get(ctx, endpoint, query, &repos); err != nil {
			return nil, err
		}
		for _, r := range repos {
			names = append(names, r.FullName)
		}
		if len(repos) < pageSize {
			break
		}
	}
	sortFold(names)
	return names, nil
}

func (c *Client) OpenPullRequests(ctx context.Context) ([]model.PullRequest, error) {
	kind, err := c.resolveOwnerKind(ctx)
	if err != nil {
		return nil, err
	}
	qual := "user"
	if kind == "Organization" {
		qual = "org"
	}
	return c.search(ctx, fmt.Sprintf("is:pr is:open %s:%s", qual, c.Owner), "", 0)
}

func (c *Client) PullRequests(ctx context.Context, since *time.Time, limit int) ([]model.PullRequest, error) {
	kind, err := c.resolveOwnerKind(ctx)
	if err != nil {
		return nil, err
	}
	qual := "user"
	if kind == "Organization" {
		qual = "org"
	}
	q := fmt.Sprintf("is:pr %s:%s", qual, c.Owner)
	if since != nil {
		q += " updated:>=" + since.UTC().Format(time.RFC3339)
	}
	return c.search(ctx, q, "updated", limit)
}

func (c *Client) search(ctx context.Context, q, sortKey string, limit int) ([]model.PullRequest, error) {
	var result []model.PullRequest
	for page := 1; page <= maxPages; page++ {
		query := url.Values{}
		query.Set("q", q)
		query.Set("per_page", fmt.Sprint(pageSize))
		query.Set("page", fmt.Sprint(page))
		if sortKey != "" {
			query.Set("sort", sortKey)
			query.Set("order", "desc")
		}
		var response searchDTO
		if err := c.get(ctx, c.api()+"/search/issues", query, &response); err != nil {
			return nil, err
		}
		for _, item := range response.Items {
			pr, err := c.makePR(item)
			if err != nil {
				return nil, err
			}
			result = append(result, pr)
		}
		if limit > 0 && len(result) >= limit {
			break
		}
		if len(response.Items) < pageSize || len(result) >= response.TotalCount {
			break
		}
	}
	if limit > 0 && len(result) > limit {
		result = result[:limit]
	}
	return result, nil
}

func (c *Client) Tags(ctx context.Context, repos []string) (model.TagFetch, error) {
	var fetch model.TagFetch
	for _, repo := range repos {
		unavailable := false
		for page := 1; page <= maxPages; page++ {
			query := url.Values{}
			query.Set("per_page", fmt.Sprint(pageSize))
			query.Set("page", fmt.Sprint(page))
			var dtos []struct {
				Name string `json:"name"`
			}
			err := c.get(ctx, c.api()+"/repos/"+repo+"/tags", query, &dtos)
			if err != nil {
				if pe, ok := provider.AsError(err); ok && (pe.Kind == provider.KindUnauthorized || (pe.Kind == provider.KindServer && pe.Status == 404)) {
					unavailable = true
					break
				}
				return model.TagFetch{}, err
			}
			for _, dto := range dtos {
				web, ok := tagURL(repo, dto.Name)
				if !ok {
					continue
				}
				fetch.Tags = append(fetch.Tags, model.Tag{
					AccountID: c.AccountID, Repo: repo, Name: dto.Name, WebURL: web,
				})
			}
			if len(dtos) < pageSize {
				break
			}
		}
		if unavailable {
			fetch.UnavailableRepos = append(fetch.UnavailableRepos, repo)
		}
	}
	return fetch, nil
}

func tagURL(repo, tag string) (string, bool) {
	var b strings.Builder
	for _, r := range tag {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || strings.ContainsRune("-._~", r) {
			b.WriteRune(r)
			continue
		}
		fmt.Fprintf(&b, "%%%02X", r)
	}
	return "https://github.com/" + repo + "/releases/tag/" + b.String(), true
}

func (c *Client) FilePaths(ctx context.Context, repo, ref string) ([]string, error) {
	if ref == "" {
		ref = "HEAD"
	}
	var tree struct {
		Tree []struct {
			Path string `json:"path"`
			Type string `json:"type"`
		} `json:"tree"`
	}
	q := url.Values{}
	q.Set("recursive", "1")
	err := c.get(ctx, c.api()+"/repos/"+repo+"/git/trees/"+url.PathEscape(ref), q, &tree)
	if err != nil {
		if pe, ok := provider.AsError(err); ok && pe.Kind == provider.KindServer && pe.Status == 409 {
			return nil, nil
		}
		return nil, err
	}
	var paths []string
	for _, e := range tree.Tree {
		if e.Type == "blob" {
			paths = append(paths, e.Path)
		}
	}
	return paths, nil
}

func (c *Client) FileContent(ctx context.Context, repo, path, ref string) (string, error) {
	q := url.Values{}
	if ref != "" {
		q.Set("ref", ref)
	}
	data, err := c.data(ctx, c.api()+"/repos/"+repo+"/contents/"+escapePath(path), q, "application/vnd.github.raw+json")
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func (c *Client) resolveOwnerKind(ctx context.Context) (string, error) {
	if c.ownerKind != "" {
		return c.ownerKind, nil
	}
	var info struct {
		Type string `json:"type"`
	}
	if err := c.get(ctx, c.api()+"/users/"+url.PathEscape(c.Owner), nil, &info); err != nil {
		return "", err
	}
	if info.Type == "Organization" {
		c.ownerKind = "Organization"
	} else {
		c.ownerKind = "User"
	}
	return c.ownerKind, nil
}

type searchDTO struct {
	TotalCount int          `json:"total_count"`
	Items      []searchItem `json:"items"`
}

type searchItem struct {
	Number        int     `json:"number"`
	Title         string  `json:"title"`
	CreatedAt     string  `json:"created_at"`
	Draft         *bool   `json:"draft"`
	State         string  `json:"state"`
	ClosedAt      *string `json:"closed_at"`
	HTMLURL       string  `json:"html_url"`
	RepositoryURL string  `json:"repository_url"`
	User          struct {
		Login string `json:"login"`
	} `json:"user"`
	PullRequest *struct {
		MergedAt *string `json:"merged_at"`
	} `json:"pull_request"`
}

func (c *Client) makePR(item searchItem) (model.PullRequest, error) {
	created, ok := provider.ParseTime(item.CreatedAt)
	if !ok {
		return model.PullRequest{}, provider.Decoding("created_at " + item.CreatedAt)
	}
	repo, err := repoFromURL(item.RepositoryURL)
	if err != nil || item.HTMLURL == "" {
		return model.PullRequest{}, provider.Decoding(fmt.Sprintf("url in PR %d", item.Number))
	}
	state := model.PROpen
	if item.State != "" && item.State != "open" {
		if item.PullRequest != nil && item.PullRequest.MergedAt != nil && *item.PullRequest.MergedAt != "" {
			state = model.PRMerged
		} else {
			state = model.PRClosed
		}
	}
	var closed *time.Time
	if item.ClosedAt != nil {
		if t, ok := provider.ParseTime(*item.ClosedAt); ok {
			closed = &t
		}
	}
	draft := false
	if item.Draft != nil {
		draft = *item.Draft
	}
	return model.PullRequest{
		AccountID:  c.AccountID,
		Repo:       repo,
		Number:     item.Number,
		Title:      item.Title,
		AuthorID:   item.User.Login,
		AuthorName: item.User.Login,
		IsDraft:    draft,
		CreatedAt:  created,
		WebURL:     item.HTMLURL,
		State:      state,
		ClosedAt:   closed,
	}, nil
}

func (c *Client) get(ctx context.Context, endpoint string, query url.Values, dest any) error {
	data, err := c.data(ctx, endpoint, query, apiAccept)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(data, dest); err != nil {
		return provider.Decoding(err.Error())
	}
	return nil
}

func (c *Client) data(ctx context.Context, endpoint string, query url.Values, accept string) ([]byte, error) {
	u, err := url.Parse(endpoint)
	if err != nil {
		return nil, provider.Network(err.Error())
	}
	if len(query) > 0 {
		u.RawQuery = query.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, provider.Network(err.Error())
	}
	token, err := c.Token(ctx)
	if err != nil {
		if pe, ok := provider.AsError(err); ok {
			return nil, pe
		}
		return nil, provider.MissingToken()
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", accept)
	req.Header.Set("X-GitHub-Api-Version", apiVersion)
	req.Header.Set("User-Agent", "pullwatchd")
	body, _, err := provider.Do(ctx, c.HTTP, req, c.now())
	return body, err
}

func repoFromURL(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil {
		return "", err
	}
	parts := strings.Split(strings.Trim(u.Path, "/"), "/")
	if len(parts) < 2 {
		return "", fmt.Errorf("short path")
	}
	return parts[len(parts)-2] + "/" + parts[len(parts)-1], nil
}

func escapePath(p string) string {
	parts := strings.Split(p, "/")
	for i, part := range parts {
		parts[i] = url.PathEscape(part)
	}
	return strings.Join(parts, "/")
}

func cloneValues(v url.Values) url.Values {
	out := url.Values{}
	for k, vs := range v {
		out[k] = append([]string(nil), vs...)
	}
	return out
}

func sortFold(s []string) {
	for i := 1; i < len(s); i++ {
		j := i
		for j > 0 && strings.ToLower(s[j]) < strings.ToLower(s[j-1]) {
			s[j], s[j-1] = s[j-1], s[j]
			j--
		}
	}
}
