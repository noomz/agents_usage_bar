package httpclient

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

func TestGetSendsBearerAndDecodes(t *testing.T) {
	var gotAuth, gotExtra string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotExtra = r.Header.Get("Authorization"), r.Header.Get("X-Title")
		_, _ = w.Write([]byte(`{"total_usage":1.5}`))
	}))
	defer srv.Close()
	var out struct {
		TotalUsage float64 `json:"total_usage"`
	}
	key := secret.New("k")
	err := New(RemoteTimeout).GetJSON(context.Background(), srv.URL, &key, map[string]string{"X-Title": "t"}, &out)
	if err != nil || out.TotalUsage != 1.5 || gotAuth != "Bearer k" || gotExtra != "t" {
		t.Errorf("err=%v out=%+v auth=%q extra=%q", err, out, gotAuth, gotExtra)
	}
}

func TestErrorMapping(t *testing.T) {
	cases := []struct {
		status int
		kind   domain.ProviderErrorKind
		msg    string
	}{
		{401, domain.ErrAuth, "HTTP 401"},
		{403, domain.ErrAuth, "HTTP 403"},
		{402, domain.ErrPaymentRequired, "HTTP 402"},
		{500, domain.ErrHTTP, "HTTP 500"},
	}
	for _, c := range cases {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(c.status) }))
		err := New(RemoteTimeout).GetJSON(context.Background(), srv.URL, nil, nil, nil)
		srv.Close()
		var he domain.HTTPError
		if !errors.As(err, &he) || he.Status != c.status {
			t.Errorf("%d: %v", c.status, err)
		}
		if pe := domain.ProviderErrorFrom(err); pe.Kind != c.kind || pe.Message != c.msg {
			t.Errorf("%d: %+v", c.status, pe)
		}
	}
}

func TestDecodeFailureIsDecodeError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("nope")) }))
	defer srv.Close()
	var out struct{}
	err := New(RemoteTimeout).GetJSON(context.Background(), srv.URL, nil, nil, &out)
	if pe := domain.ProviderErrorFrom(err); pe.Kind != domain.ErrDecode {
		t.Errorf("%+v", pe)
	}
}

func TestPostJSON(t *testing.T) {
	var body, contentType string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		body, contentType = string(data), r.Header.Get("Content-Type")
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	c := New(RemoteTimeout)
	if err := c.PostJSON(context.Background(), srv.URL, map[string]string{"ideType": "x"}, nil, nil, nil); err != nil {
		t.Fatal(err)
	}
	if body != `{"ideType":"x"}` || contentType != "application/json" {
		t.Errorf("%q %q", body, contentType)
	}
}

func closedPort(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := l.Addr().String()
	l.Close()
	return addr
}

func TestLocalhostOutagesClassifyAsNotRunning(t *testing.T) {
	err := New(LocalhostTimeout).GetJSON(context.Background(), "http://"+closedPort(t)+"/health", nil, nil, nil)
	if s := domain.ClassifyLocalhost(err, nil); s.Kind != domain.StatusNotRunning {
		t.Errorf("refused: %+v (%v)", s, err)
	}
	var ne domain.NetworkError
	if !errors.As(err, &ne) || ne.Code != domain.NetworkCannotConnect {
		t.Errorf("code: %v", err)
	}

	stalled := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(_ http.ResponseWriter, _ *http.Request) { <-stalled }))
	defer srv.Close()
	defer close(stalled)
	start := time.Now()
	err = New(100*time.Millisecond).GetJSON(context.Background(), srv.URL, nil, nil, nil)
	if s := domain.ClassifyLocalhost(err, nil); s.Kind != domain.StatusNotRunning {
		t.Errorf("timeout: %+v (%v)", s, err)
	}
	if time.Since(start) > 5*time.Second {
		t.Errorf("timeout took %v", time.Since(start))
	}

	s := domain.ClassifyLocalhost(domain.HTTPError{Status: 500}, nil)
	if s.Kind != domain.StatusError {
		t.Errorf("5xx means the server is up: %+v", s)
	}
	last := time.Unix(1000, 0)
	s = domain.ClassifyLocalhost(domain.HTTPError{Status: 500}, &last)
	if s.Kind != domain.StatusStale || !strings.Contains(s.Err.Message, "500") {
		t.Errorf("stale: %+v", s)
	}
}

func TestTierTimeouts(t *testing.T) {
	cases := []struct {
		timeout, total time.Duration
	}{
		{RemoteTimeout, 32 * time.Second},
		{LocalhostTimeout, 30 * time.Second},
	}
	for _, c := range cases {
		h := New(c.timeout)
		if h.client.Timeout != c.total {
			t.Errorf("%v: total %v", c.timeout, h.client.Timeout)
		}
		if h.client.Transport.(*http.Transport).ResponseHeaderTimeout != c.timeout {
			t.Errorf("%v: header timeout", c.timeout)
		}
		if h.client.Jar != nil {
			t.Error("no cookies")
		}
	}
}
