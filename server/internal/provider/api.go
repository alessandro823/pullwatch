package provider

import (
	"context"
	"time"

	"github.com/alessandro823/pullwatch/server/internal/model"
)

// Source is one GitHub owner or Azure DevOps organisation.
type Source interface {
	CurrentUserID(ctx context.Context) (string, error)
	ListRepos(ctx context.Context) ([]string, error)
	OpenPullRequests(ctx context.Context) ([]model.PullRequest, error)
	// PullRequests returns pull requests in every state, newest first, capped at limit.
	// since limits the window (GitHub: updated since; Azure DevOps: created or closed since).
	PullRequests(ctx context.Context, since *time.Time, limit int) ([]model.PullRequest, error)
	Tags(ctx context.Context, repos []string) (model.TagFetch, error)
	// FilePaths lists paths on ref, or on the default branch when ref is empty.
	// An empty repository returns an empty list.
	FilePaths(ctx context.Context, repo, ref string) ([]string, error)
	FileContent(ctx context.Context, repo, path, ref string) (string, error)
	Invalidate(ctx context.Context)
}
