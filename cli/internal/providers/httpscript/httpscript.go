// Package httpscript is a scripted httpclient.Client for provider tests.
package httpscript

import (
	"context"
	"encoding/json"
	"net/url"
	"sync"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

// Reply is one scripted answer: an error, or a body decoded as the real client decodes it.
type Reply struct {
	Body string
	Err  error
}

// JSON answers with a body.
func JSON(body string) Reply { return Reply{Body: body} }

// Fail answers with an error.
func Fail(err error) Reply { return Reply{Err: err} }

// Refused is a connection-refused transport failure.
func Refused() Reply {
	return Fail(domain.NetworkError{Code: domain.NetworkCannotConnect, Err: context.Canceled})
}

// Status is a non-2xx response.
func Status(code int) Reply { return Fail(domain.HTTPError{Status: code}) }

// Call is one recorded request. Bearer is "" when none was sent.
type Call struct {
	Method, URL, Path, Bearer string
	Headers                   map[string]string
}

// Client answers "METHOD /path" keys from a script. The last reply for a key repeats, and an
// unscripted key answers HTTP 599, or connection refused on a Refusing client.
type Client struct {
	mu       sync.Mutex
	replies  map[string][]Reply
	fallback Reply
	calls    []Call
}

// New builds an empty script.
func New() *Client { return &Client{replies: map[string][]Reply{}, fallback: Status(599)} }

// Refusing is a host where nothing is listening.
func Refusing() *Client { return &Client{replies: map[string][]Reply{}, fallback: Refused()} }

// Script appends replies for a key such as "GET /api/ps".
func (c *Client) Script(key string, replies ...Reply) *Client {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.replies[key] = append(c.replies[key], replies...)
	return c
}

// Calls returns the recorded requests.
func (c *Client) Calls() []Call {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]Call(nil), c.calls...)
}

// Count is the number of requests for a key.
func (c *Client) Count(key string) int {
	n := 0
	for _, call := range c.Calls() {
		if call.Method+" "+call.Path == key {
			n++
		}
	}
	return n
}

func (c *Client) answer(method, rawURL string, bearer *secret.Secret, headers map[string]string, out any) error {
	u, err := url.Parse(rawURL)
	if err != nil {
		return err
	}
	key := method + " " + u.Path
	call := Call{Method: method, URL: rawURL, Path: u.Path, Headers: headers}
	if bearer != nil {
		call.Bearer = bearer.Reveal()
	}
	c.mu.Lock()
	c.calls = append(c.calls, call)
	queue := c.replies[key]
	reply := c.fallback
	if len(queue) > 0 {
		reply = queue[0]
		if len(queue) > 1 {
			c.replies[key] = queue[1:]
		}
	}
	c.mu.Unlock()
	if reply.Err != nil {
		return reply.Err
	}
	if out == nil {
		return nil
	}
	if err := json.Unmarshal([]byte(reply.Body), out); err != nil {
		return domain.DecodeError{Err: err}
	}
	return nil
}

func (c *Client) GetJSON(_ context.Context, rawURL string, bearer *secret.Secret, headers map[string]string, out any) error {
	return c.answer("GET", rawURL, bearer, headers, out)
}

func (c *Client) PostJSON(_ context.Context, rawURL string, _ any, bearer *secret.Secret, headers map[string]string, out any) error {
	return c.answer("POST", rawURL, bearer, headers, out)
}
