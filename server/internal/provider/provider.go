// Package provider is the seam between the poller and GitHub / Azure DevOps.
package provider

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// Error is a failure the poller knows how to schedule around.
type Error struct {
	Kind    string
	Status  int
	Until   time.Time
	Message string
}

const (
	KindUnauthorized = "unauthorized"
	KindRateLimited  = "rate_limited"
	KindServer       = "server"
	KindNetwork      = "network"
	KindDecoding     = "decoding"
	KindMissingToken = "missing_token"
	KindNoAccess     = "no_access"
)

func (e *Error) Error() string { return e.UserMessage() }

func (e *Error) UserMessage() string {
	if e == nil {
		return ""
	}
	switch e.Kind {
	case KindUnauthorized:
		return "Token invalid or expired"
	case KindRateLimited:
		return "Rate limit, retry at " + e.Until.UTC().Format("15:04")
	case KindServer:
		return fmt.Sprintf("Server error (%d)", e.Status)
	case KindNetwork:
		return "Network error: " + e.Message
	case KindDecoding:
		return "Unexpected response: " + e.Message
	case KindMissingToken:
		return "No token set"
	case KindNoAccess:
		return fmt.Sprintf("No access to %q, check the name", e.Message)
	default:
		if e.Message != "" {
			return e.Message
		}
		return "Unknown error"
	}
}

// Equal matches the Mac app's Equatable comparison, including the rate-limit deadline.
func (e *Error) Equal(other *Error) bool {
	if e == nil || other == nil {
		return e == other
	}
	if e.Kind != other.Kind || e.Status != other.Status || e.Message != other.Message {
		return false
	}
	return e.Until.Equal(other.Until)
}

func Unauthorized() *Error { return &Error{Kind: KindUnauthorized} }
func MissingToken() *Error { return &Error{Kind: KindMissingToken} }
func NoAccess(name string) *Error {
	return &Error{Kind: KindNoAccess, Message: name}
}
func Server(status int) *Error   { return &Error{Kind: KindServer, Status: status} }
func Network(msg string) *Error  { return &Error{Kind: KindNetwork, Message: msg} }
func Decoding(msg string) *Error { return &Error{Kind: KindDecoding, Message: msg} }
func RateLimited(until time.Time) *Error {
	return &Error{Kind: KindRateLimited, Until: until}
}

// AsError unwraps a provider error.
func AsError(err error) (*Error, bool) {
	if err == nil {
		return nil, false
	}
	if pe, ok := err.(*Error); ok {
		return pe, true
	}
	return nil, false
}

// HTTPDoer is the subset of http.Client the providers use. Tests substitute it.
type HTTPDoer interface {
	Do(req *http.Request) (*http.Response, error)
}

// CheckStatus maps an HTTP status onto a provider error. 203 is Azure DevOps'
// HTML login page for a bad PAT.
func CheckStatus(resp *http.Response, now time.Time) error {
	status := resp.StatusCode
	switch {
	case status == 203:
		return Unauthorized()
	case status >= 200 && status < 300:
		return nil
	case status == http.StatusUnauthorized:
		return Unauthorized()
	case status == http.StatusForbidden || status == http.StatusTooManyRequests:
		if sec, err := strconv.ParseFloat(strings.TrimSpace(resp.Header.Get("Retry-After")), 64); err == nil {
			return RateLimited(now.Add(time.Duration(sec * float64(time.Second))))
		}
		if resp.Header.Get("X-RateLimit-Remaining") == "0" {
			if epoch, err := strconv.ParseFloat(strings.TrimSpace(resp.Header.Get("X-RateLimit-Reset")), 64); err == nil {
				return RateLimited(time.Unix(int64(epoch), 0))
			}
		}
		if status == http.StatusTooManyRequests {
			return RateLimited(now.Add(60 * time.Second))
		}
		return Unauthorized()
	default:
		return Server(status)
	}
}

// ReadJSONBody reads and closes the body, checking the status first.
func ReadBody(resp *http.Response, now time.Time) ([]byte, error) {
	defer resp.Body.Close()
	if err := CheckStatus(resp, now); err != nil {
		_, _ = io.Copy(io.Discard, resp.Body)
		return nil, err
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, Network(err.Error())
	}
	return data, nil
}

// Do sends req and reads the body, turning transport errors into Network.
func Do(ctx context.Context, httpClient HTTPDoer, req *http.Request, now time.Time) ([]byte, *http.Response, error) {
	req = req.WithContext(ctx)
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, nil, Network(err.Error())
	}
	body, err := ReadBody(resp, now)
	if err != nil {
		return nil, resp, err
	}
	return body, resp, nil
}
