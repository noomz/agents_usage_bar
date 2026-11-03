// Package httpclient is the shared HTTP client: one transport per tier, no cache, no cookies,
// and JSON in and out. Logging never sees a URL query, a header, or a body.
package httpclient

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"syscall"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

// The two tiers. Localhost probes fail fast so a stopped runtime never delays the report.
const (
	RemoteTimeout    = 8 * time.Second
	LocalhostTimeout = 2 * time.Second
)

// Client is the HTTP seam providers use. Non-2xx responses return domain.HTTPError; transport
// failures return domain.NetworkError; a body that does not match out returns
// domain.DecodeError. `out` is decoded with encoding/json, so declare JSON field names with
// struct tags. A nil out skips decoding.
type Client interface {
	// GetJSON sends a GET. A nil bearer sends no Authorization header.
	GetJSON(ctx context.Context, rawURL string, bearer *secret.Secret, headers map[string]string, out any) error
	// PostJSON sends body as JSON. A nil bearer sends no Authorization header.
	PostJSON(ctx context.Context, rawURL string, body any, bearer *secret.Secret, headers map[string]string, out any) error
}

// HTTP is the production Client.
type HTTP struct {
	client *http.Client
}

// New builds a Client whose connect, TLS, and response-header waits are each bounded by
// timeout, and whose whole exchange is bounded by max(timeout*4, 30s).
func New(timeout time.Duration) *HTTP {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.MaxConnsPerHost = 6
	transport.ResponseHeaderTimeout = timeout
	transport.TLSHandshakeTimeout = timeout
	transport.DialContext = (&net.Dialer{Timeout: timeout}).DialContext
	total := timeout * 4
	if total < 30*time.Second {
		total = 30 * time.Second
	}
	return &HTTP{client: &http.Client{Transport: transport, Timeout: total}}
}

// GetJSON implements Client.
func (c *HTTP) GetJSON(ctx context.Context, rawURL string, bearer *secret.Secret, headers map[string]string, out any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	return c.do(req, bearer, headers, out)
}

// PostJSON implements Client.
func (c *HTTP) PostJSON(ctx context.Context, rawURL string, body any, bearer *secret.Secret, headers map[string]string, out any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, rawURL, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	return c.do(req, bearer, headers, out)
}

func (c *HTTP) do(req *http.Request, bearer *secret.Secret, headers map[string]string, out any) error {
	if bearer != nil {
		req.Header.Set("Authorization", "Bearer "+bearer.Reveal())
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return classify(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, resp.Body)
		return domain.HTTPError{Status: resp.StatusCode}
	}
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return classify(err)
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return domain.DecodeError{Err: err}
	}
	return nil
}

func classify(err error) error {
	code := domain.NetworkOther
	var dns *net.DNSError
	var timeout interface{ Timeout() bool }
	switch {
	case errors.As(err, &dns):
		code = domain.NetworkCannotFindHost
	case errors.Is(err, syscall.ECONNREFUSED), errors.Is(err, syscall.EHOSTUNREACH), errors.Is(err, syscall.ENETUNREACH):
		code = domain.NetworkCannotConnect
	case errors.Is(err, context.DeadlineExceeded), errors.As(err, &timeout) && timeout.Timeout():
		code = domain.NetworkTimedOut
	case errors.Is(err, syscall.ECONNRESET), errors.Is(err, syscall.EPIPE), errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		code = domain.NetworkConnectionLost
	}
	return domain.NetworkError{Code: code, Err: err}
}
