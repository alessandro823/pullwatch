// Package azure talks to dev.azure.com for one organisation.
package azure

import (
	"context"
	"encoding/base64"
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
	pageSize        = 100
	anonymousUserID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
	projectCacheTTL = time.Hour
)

// Client is one Azure DevOps organisation.
// Auth is "pat" (HTTP basic) or "bearer".
type Client struct {
	AccountID    string
	Organization string
	Auth         string
	Token        func(context.Context) (string, error)
	HTTP         provider.HTTPDoer
	Now          func() time.Time
	base         string

	projects   []string
	projectsAt time.Time
}

func (c *Client) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c *Client) root() string {
	if c.base != "" {
		return strings.TrimRight(c.base, "/") + "/" + url.PathEscape(c.Organization)
	}
	return "https://dev.azure.com/" + url.PathEscape(c.Organization)
}

func (c *Client) Invalidate(context.Context) {
	c.projects = nil
	c.projectsAt = time.Time{}
}

func (c *Client) CurrentUserID(ctx context.Context) (string, error) {
	user, err := c.authenticatedUser(ctx)
	if err != nil {
		return "", err
	}
	return user.ID, nil
}

func (c *Client) TestConnection(ctx context.Context) (string, error) {
	user, err := c.authenticatedUser(ctx)
	if err != nil {
		return "", err
	}
	q := url.Values{}
	q.Set("$top", "1")
	var list valueList[projectDTO]
	if err := c.get(ctx, c.root()+"/_apis/projects", "7.1", q, &list); err != nil {
		if pe, ok := provider.AsError(err); ok && pe.Kind == provider.KindUnauthorized {
			return "", provider.NoAccess(c.Organization)
		}
		return "", err
	}
	if user.ProviderDisplayName != "" {
		return user.ProviderDisplayName, nil
	}
	return user.ID, nil
}

func (c *Client) authenticatedUser(ctx context.Context) (connectionUser, error) {
	var data struct {
		AuthenticatedUser connectionUser `json:"authenticatedUser"`
	}
	if err := c.get(ctx, c.root()+"/_apis/connectionData", "7.1-preview", nil, &data); err != nil {
		return connectionUser{}, err
	}
	if data.AuthenticatedUser.ID == anonymousUserID {
		return connectionUser{}, provider.Unauthorized()
	}
	return data.AuthenticatedUser, nil
}

func (c *Client) ListRepos(ctx context.Context) ([]string, error) {
	projects, err := c.projectNames(ctx)
	if err != nil {
		return nil, err
	}
	var result []string
	for _, project := range projects {
		var list valueList[struct {
			Name string `json:"name"`
		}]
		if err := c.get(ctx, c.root()+"/"+url.PathEscape(project)+"/_apis/git/repositories", "7.1", nil, &list); err != nil {
			return nil, err
		}
		for _, repo := range list.Value {
			result = append(result, project+"/"+repo.Name)
		}
	}
	sortFold(result)
	return result, nil
}

func (c *Client) OpenPullRequests(ctx context.Context) ([]model.PullRequest, error) {
	projects, err := c.projectNames(ctx)
	if err != nil {
		return nil, err
	}
	var result []model.PullRequest
	for _, project := range projects {
		skip := 0
		for {
			q := url.Values{}
			q.Set("searchCriteria.status", "active")
			q.Set("$top", fmt.Sprint(pageSize))
			q.Set("$skip", fmt.Sprint(skip))
			var page valueList[pullRequestDTO]
			if err := c.get(ctx, c.root()+"/"+url.PathEscape(project)+"/_apis/git/pullrequests", "7.1", q, &page); err != nil {
				return nil, err
			}
			for _, dto := range page.Value {
				pr, err := c.makePR(dto)
				if err != nil {
					return nil, err
				}
				result = append(result, pr)
			}
			if len(page.Value) < pageSize {
				break
			}
			skip += pageSize
		}
	}
	return result, nil
}

func (c *Client) PullRequests(ctx context.Context, since *time.Time, limit int) ([]model.PullRequest, error) {
	projects, err := c.projectNames(ctx)
	if err != nil {
		return nil, err
	}
	byID := map[int]model.PullRequest{}
	var ranges []string
	if since == nil {
		ranges = []string{""}
	} else {
		ranges = []string{"created", "closed"}
	}
	fetched := make([]int, len(ranges))
	for _, project := range projects {
		for series, rng := range ranges {
			if fetched[series] >= limit {
				continue
			}
			skip := 0
			for {
				q := url.Values{}
				q.Set("searchCriteria.status", "all")
				q.Set("$top", fmt.Sprint(pageSize))
				q.Set("$skip", fmt.Sprint(skip))
				if rng != "" && since != nil {
					q.Set("searchCriteria.queryTimeRangeType", rng)
					q.Set("searchCriteria.minTime", since.UTC().Format(time.RFC3339))
				}
				var page valueList[pullRequestDTO]
				err := c.get(ctx, c.root()+"/"+url.PathEscape(project)+"/_apis/git/pullrequests", "7.1", q, &page)
				if err != nil {
					if pe, ok := provider.AsError(err); ok && pe.Kind == provider.KindServer && pe.Status == 404 {
						break
					}
					return nil, err
				}
				for _, dto := range page.Value {
					pr, err := c.makePR(dto)
					if err != nil {
						return nil, err
					}
					byID[dto.PullRequestID] = pr
				}
				fetched[series] += len(page.Value)
				if len(page.Value) < pageSize || fetched[series] >= limit {
					break
				}
				skip += pageSize
			}
		}
		done := true
		for _, n := range fetched {
			if n < limit {
				done = false
			}
		}
		if done {
			break
		}
	}
	out := make([]model.PullRequest, 0, len(byID))
	for _, pr := range byID {
		out = append(out, pr)
	}
	sortByCreatedDesc(out)
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (c *Client) Tags(ctx context.Context, repos []string) (model.TagFetch, error) {
	var fetch model.TagFetch
	for _, repo := range repos {
		project, name, ok := splitRepo(repo)
		if !ok {
			continue
		}
		q := url.Values{}
		q.Set("filter", "tags/")
		var list valueList[refDTO]
		err := c.get(ctx, c.root()+"/"+url.PathEscape(project)+"/_apis/git/repositories/"+url.PathEscape(name)+"/refs", "7.1", q, &list)
		if err != nil {
			if pe, ok := provider.AsError(err); ok && (pe.Kind == provider.KindUnauthorized || (pe.Kind == provider.KindServer && pe.Status == 404)) {
				fetch.UnavailableRepos = append(fetch.UnavailableRepos, repo)
				continue
			}
			return model.TagFetch{}, err
		}
		for _, ref := range list.Value {
			tagName := ref.Name
			if strings.HasPrefix(tagName, "refs/tags/") {
				tagName = strings.TrimPrefix(tagName, "refs/tags/")
			}
			author := ""
			if ref.Creator != nil {
				author = ref.Creator.DisplayName
			}
			fetch.Tags = append(fetch.Tags, model.Tag{
				AccountID:  c.AccountID,
				Repo:       repo,
				Name:       tagName,
				AuthorName: author,
				WebURL:     c.tagURL(project, name, tagName),
			})
		}
	}
	return fetch, nil
}

func (c *Client) tagURL(project, repo, tag string) string {
	var b strings.Builder
	for _, r := range tag {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || strings.ContainsRune("-._~/", r) {
			b.WriteRune(r)
			continue
		}
		fmt.Fprintf(&b, "%%%02X", r)
	}
	return c.root() + "/" + url.PathEscape(project) + "/_git/" + url.PathEscape(repo) + "?version=GT" + b.String()
}

func (c *Client) FilePaths(ctx context.Context, repo, ref string) ([]string, error) {
	q := url.Values{}
	q.Set("scopePath", "/")
	q.Set("recursionLevel", "Full")
	versionQuery(q, ref)
	var list valueList[itemDTO]
	err := c.get(ctx, c.itemsURL(repo), "7.1", q, &list)
	if err != nil {
		if pe, ok := provider.AsError(err); ok && pe.Kind == provider.KindServer && pe.Status == 404 {
			return nil, nil
		}
		return nil, err
	}
	var paths []string
	for _, item := range list.Value {
		if item.IsFolder != nil && *item.IsFolder {
			continue
		}
		paths = append(paths, strings.TrimLeft(item.Path, "/"))
	}
	return paths, nil
}

func (c *Client) FileContent(ctx context.Context, repo, path, ref string) (string, error) {
	q := url.Values{}
	q.Set("path", "/"+path)
	q.Set("includeContent", "true")
	versionQuery(q, ref)
	var item itemDTO
	if err := c.get(ctx, c.itemsURL(repo), "7.1", q, &item); err != nil {
		return "", err
	}
	return item.Content, nil
}

func versionQuery(q url.Values, tag string) {
	if tag == "" {
		return
	}
	q.Set("versionDescriptor.version", tag)
	q.Set("versionDescriptor.versionType", "tag")
}

func (c *Client) itemsURL(repo string) string {
	project, name, ok := splitRepo(repo)
	if !ok {
		project, name = repo, repo
	}
	return c.root() + "/" + url.PathEscape(project) + "/_apis/git/repositories/" + url.PathEscape(name) + "/items"
}

func (c *Client) projectNames(ctx context.Context) ([]string, error) {
	if c.projects != nil && c.now().Sub(c.projectsAt) < projectCacheTTL {
		return c.projects, nil
	}
	q := url.Values{}
	q.Set("$top", "500")
	var list valueList[projectDTO]
	if err := c.get(ctx, c.root()+"/_apis/projects", "7.1", q, &list); err != nil {
		return nil, err
	}
	names := make([]string, 0, len(list.Value))
	for _, p := range list.Value {
		names = append(names, p.Name)
	}
	c.projects = names
	c.projectsAt = c.now()
	return names, nil
}

func (c *Client) makePR(dto pullRequestDTO) (model.PullRequest, error) {
	created, ok := provider.ParseTime(dto.CreationDate)
	if !ok {
		return model.PullRequest{}, provider.Decoding("creationDate " + dto.CreationDate)
	}
	state := model.PROpen
	switch dto.Status {
	case "completed":
		state = model.PRMerged
	case "abandoned":
		state = model.PRClosed
	}
	var closed *time.Time
	if dto.ClosedDate != nil {
		if t, ok := provider.ParseTime(*dto.ClosedDate); ok {
			closed = &t
		}
	}
	project := dto.Repository.Project.Name
	web := c.root() + "/" + url.PathEscape(project) + "/_git/" + url.PathEscape(dto.Repository.Name) + "/pullrequest/" + fmt.Sprint(dto.PullRequestID)
	draft := false
	if dto.IsDraft != nil {
		draft = *dto.IsDraft
	}
	return model.PullRequest{
		AccountID:  c.AccountID,
		Repo:       project + "/" + dto.Repository.Name,
		Number:     dto.PullRequestID,
		Title:      dto.Title,
		AuthorID:   dto.CreatedBy.ID,
		AuthorName: dto.CreatedBy.DisplayName,
		IsDraft:    draft,
		CreatedAt:  created,
		WebURL:     web,
		State:      state,
		ClosedAt:   closed,
	}, nil
}

func (c *Client) authorization(ctx context.Context) (string, error) {
	token, err := c.Token(ctx)
	if err != nil {
		if pe, ok := provider.AsError(err); ok {
			return "", pe
		}
		return "", provider.MissingToken()
	}
	if c.Auth == "bearer" {
		return "Bearer " + token, nil
	}
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(":"+token)), nil
}

func (c *Client) get(ctx context.Context, endpoint, apiVersion string, query url.Values, dest any) error {
	if query == nil {
		query = url.Values{}
	}
	query.Set("api-version", apiVersion)
	u, err := url.Parse(endpoint)
	if err != nil {
		return provider.Network(err.Error())
	}
	u.RawQuery = query.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return provider.Network(err.Error())
	}
	auth, err := c.authorization(ctx)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", auth)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", "pullwatchd")
	body, _, err := provider.Do(ctx, c.HTTP, req, c.now())
	if err != nil {
		return err
	}
	if err := json.Unmarshal(body, dest); err != nil {
		return provider.Decoding(err.Error())
	}
	return nil
}

type valueList[T any] struct {
	Value []T `json:"value"`
}

type connectionUser struct {
	ID                  string `json:"id"`
	ProviderDisplayName string `json:"providerDisplayName"`
}

type projectDTO struct {
	Name string `json:"name"`
}

type pullRequestDTO struct {
	PullRequestID int     `json:"pullRequestId"`
	Title         string  `json:"title"`
	IsDraft       *bool   `json:"isDraft"`
	Status        string  `json:"status"`
	ClosedDate    *string `json:"closedDate"`
	CreationDate  string  `json:"creationDate"`
	CreatedBy     struct {
		ID          string `json:"id"`
		DisplayName string `json:"displayName"`
	} `json:"createdBy"`
	Repository struct {
		Name    string `json:"name"`
		Project struct {
			Name string `json:"name"`
		} `json:"project"`
	} `json:"repository"`
}

type refDTO struct {
	Name    string `json:"name"`
	Creator *struct {
		DisplayName string `json:"displayName"`
	} `json:"creator"`
}

type itemDTO struct {
	Path     string `json:"path"`
	IsFolder *bool  `json:"isFolder"`
	Content  string `json:"content"`
}

func splitRepo(repo string) (project, name string, ok bool) {
	i := strings.IndexByte(repo, '/')
	if i <= 0 || i == len(repo)-1 {
		return "", "", false
	}
	return repo[:i], repo[i+1:], true
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

func sortByCreatedDesc(prs []model.PullRequest) {
	for i := 1; i < len(prs); i++ {
		j := i
		for j > 0 && prs[j].CreatedAt.After(prs[j-1].CreatedAt) {
			prs[j], prs[j-1] = prs[j-1], prs[j]
			j--
		}
	}
}
