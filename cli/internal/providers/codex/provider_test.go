package codex

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/paths"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

type whamCall struct {
	token     string
	accountID *string
	headers   map[string]string
}

// fakeHTTP answers wham/usage by account id, with "" for a call that sends no account header.
type fakeHTTP struct {
	mu        sync.Mutex
	responses map[string]any
	calls     []whamCall
}

func (f *fakeHTTP) GetJSON(_ context.Context, rawURL string, bearer *secret.Secret, headers map[string]string, out any) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if rawURL != usageURL {
		return fmt.Errorf("unexpected url %s", rawURL)
	}
	call := whamCall{token: bearer.Reveal(), headers: headers}
	key := ""
	if id, ok := headers["ChatGPT-Account-Id"]; ok {
		call.accountID, key = &id, id
	}
	f.calls = append(f.calls, call)
	switch r := f.responses[key].(type) {
	case error:
		return r
	case string:
		if err := json.Unmarshal([]byte(r), out); err != nil {
			return domain.DecodeError{Err: err}
		}
		return nil
	}
	return domain.HTTPError{Status: 599}
}

func (f *fakeHTTP) PostJSON(context.Context, string, any, *secret.Secret, map[string]string, any) error {
	return errors.New("unexpected POST")
}

// recordingCache keeps offsets so a second fetch can resume.
type recordingCache struct {
	cache.Noop
	offsets map[string]domain.TranscriptOffset
	writes  int
}

func (c *recordingCache) AllTranscriptOffsets() map[string]domain.TranscriptOffset { return c.offsets }

func (c *recordingCache) SetTranscriptOffsets(offsets []domain.TranscriptOffset) {
	c.writes++
	if c.offsets == nil {
		c.offsets = map[string]domain.TranscriptOffset{}
	}
	for _, o := range offsets {
		c.offsets[o.URL] = o
	}
}

var testNow = time.Date(2026, 10, 7, 2, 40, 0, 0, time.UTC)

type home struct {
	t    *testing.T
	root string
	http *fakeHTTP
	c    *recordingCache
}

func newHome(t *testing.T) *home {
	return &home{t: t, root: t.TempDir(), http: &fakeHTTP{responses: map[string]any{}}, c: &recordingCache{}}
}

func (h *home) rollout(day, name, contents string) string {
	h.t.Helper()
	dir := filepath.Join(append([]string{h.root, ".codex", "sessions"}, strings.Split(day, "-")...)...)
	writeAll(h.t, dir, map[string]string{name: contents})
	return filepath.Join(dir, name)
}

func (h *home) auth(contents string) {
	h.t.Helper()
	writeAll(h.t, filepath.Join(h.root, ".codex"), map[string]string{"auth.json": contents})
}

func (h *home) proxy(filename, accountID, token, email string) {
	h.t.Helper()
	writeAll(h.t, filepath.Join(h.root, ".ccs", "cliproxy", "auth"), map[string]string{filename: proxyFile(accountID, token, email, "")})
}

func (h *home) build() provider.Provider {
	h.t.Helper()
	return Build(provider.Env{
		HTTP:    h.http,
		Cache:   h.c,
		DayKeys: domain.NewDayKeyOwner(clock.Fixed(testNow), time.UTC),
		Paths:   paths.Layout{Home: h.root},
	})
}

func usageBody(plan string, primary, secondary float64) string {
	return fmt.Sprintf(`{"plan_type":%q,"rate_limit":{"primary_window":{"used_percent":%v,"reset_at":1800000000,"limit_window_seconds":18000},"secondary_window":{"used_percent":%v,"reset_at":1900000000,"limit_window_seconds":604800}}}`, plan, primary, secondary)
}

const windowless = `{"limit_id":"codex","primary":null,"secondary":null,"plan_type":null,"rate_limit_reached_type":null}`
const liveWindows = `{"limit_id":"codex","primary":{"used_percent":40,"window_minutes":300,"resets_at":1800000000},"secondary":{"used_percent":60,"window_minutes":10080,"resets_at":1900000000},"plan_type":"pro","credits":{"balance":"100.50"}}`

func closeTo(t *testing.T, got *domain.Quota, want float64) {
	t.Helper()
	if got == nil || math.Abs(got.Fraction()-want) > 1e-9 {
		t.Fatalf("quota = %+v, want %v", got, want)
	}
}

func TestBuildRequiresCredentialsSessionsOrALogin(t *testing.T) {
	cases := []struct {
		name  string
		setup func(*home)
		built bool
	}{
		{name: "nothing, the Linux host with no Codex", setup: func(*home) {}},
		{name: "unusable auth", setup: func(h *home) { h.auth("{") }},
		{name: "credentials", setup: func(h *home) { h.auth(authFile(nil, "t")) }, built: true},
		{name: "api key", setup: func(h *home) { h.auth(`{"OPENAI_API_KEY":"k"}`) }, built: true},
		{name: "sessions dir", setup: func(h *home) { h.rollout("2020-01-01", "a.jsonl", "") }, built: true},
		{name: "one CLIProxy login", setup: func(h *home) { h.proxy("codex-a-a@example.com-plus.json", "a", "t", "a@example.com") }, built: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHome(t)
			tc.setup(h)
			if built := h.build() != nil; built != tc.built {
				t.Fatalf("built = %v", built)
			}
		})
	}
}

func TestFixtureRolloutSnapshot(t *testing.T) {
	line := ""
	data, err := os.ReadFile(fixtures + "codex-rollout-2026-fixture.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	for _, l := range strings.Split(string(data), "\n") {
		if strings.Contains(l, `"total_tokens":556469`) {
			line = l
		}
	}
	h := newHome(t)
	h.auth(authFile(ptr("acc"), "t"))
	h.rollout("2026-10-07", "fixture.jsonl", line)
	p := h.build()
	snap, err := p.Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if *snap.TokensToday != 556469 {
		t.Fatalf("tokens = %d", *snap.TokensToday)
	}
	if got := snap.CostTodayUSD.Float64(); math.Abs(got-0.061586) > 1e-4 {
		t.Fatalf("cost = %v", got)
	}
	if len(snap.QuotaWindows) != 2 || snap.QuotaWindows[0].Name != "primary" || snap.QuotaWindows[1].Name != "secondary" {
		t.Fatalf("windows = %+v", snap.QuotaWindows)
	}
	if *snap.QuotaWindows[0].Utilization != 0.02 || *snap.QuotaWindows[0].Duration != 18000 || snap.QuotaWindows[0].ResetsAt.Unix() != 1777024786 {
		t.Fatalf("primary = %+v", snap.QuotaWindows[0])
	}
	closeTo(t, snap.Quota, 0.02)
	if snap.Raw["source"] != "rollout" || snap.Raw["fileURL"] != "fixture.jsonl" || p.Status().Kind != domain.StatusOK {
		t.Fatalf("raw = %v status = %v", snap.Raw, p.Status().Kind)
	}
	if len(h.http.calls) != 0 {
		t.Fatalf("rollout windows win but wham was called")
	}
}

func TestLegacyResetIsNowPlusSeconds(t *testing.T) {
	data, err := os.ReadFile(fixtures + "codex-rollout-2025-legacy.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	h := newHome(t)
	h.rollout("2026-10-07", "legacy.jsonl", string(data))
	snap, err := h.build().Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if !snap.QuotaWindows[0].ResetsAt.Equal(testNow.Add(300 * time.Second)) {
		t.Fatalf("reset = %v", snap.QuotaWindows[0].ResetsAt)
	}
}

func TestCost(t *testing.T) {
	cases := []struct {
		name  string
		usage tokenUsage
		want  string
	}{
		{"one million input", tokenUsage{InputTokens: 1_000_000}, "0.75"},
		{"cached at the cached rate", tokenUsage{InputTokens: 1_000_000, CachedInputTokens: 500_000}, "0.3875"},
		{"cached above input does not go negative", tokenUsage{InputTokens: 1, CachedInputTokens: 1_000_000}, "0.025"},
		{"output", tokenUsage{OutputTokens: 1_000_000}, "3"},
	}
	r := loadRatesOrFail(t)
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := r.cost(tc.usage); got.Cmp(decimal.MustParse(tc.want)) != 0 {
				t.Fatalf("cost = %s, want %s", got, tc.want)
			}
		})
	}
}

func loadRatesOrFail(t *testing.T) *rates {
	t.Helper()
	data, err := os.ReadFile(fixtures + "codex-models-fixture.json")
	if err != nil {
		t.Fatal(err)
	}
	r := loadRates(data)
	if r == nil {
		t.Fatal("fixture rates did not load")
	}
	return r
}

func TestFallback(t *testing.T) {
	const oneLoginFile = "codex-aaaaaaaa-a@example.com-plus.json"
	cases := []struct {
		name       string
		setup      func(*home)
		responses  map[string]any
		wantErr    bool
		status     domain.StatusKind
		source     string
		noData     bool
		tokens     *int
		quota      *float64
		whamCalls  int
		wantToken  string
		wantHeader *string
	}{
		{
			name: "no rollout, wham success is the whole row", setup: func(h *home) { h.auth(authFile(ptr("acc"), "t")) },
			responses: map[string]any{"acc": usageBody("plus", 48, 26)},
			status:    domain.StatusOK, source: "oauth-wham-usage", quota: fp(0.48), whamCalls: 1, wantToken: "t", wantHeader: ptr("acc"),
		},
		{
			name: "no rollout, no credentials is muted", setup: func(h *home) { h.rollout("2020-01-01", "old.jsonl", "") },
			status: domain.StatusUnauthenticated, noData: true,
		},
		{
			name: "no rollout, 401 is muted", setup: func(h *home) { h.auth(authFile(ptr("acc"), "t")) },
			responses: map[string]any{"acc": domain.HTTPError{Status: 401}},
			status:    domain.StatusUnauthenticated, noData: true, whamCalls: 1,
		},
		{
			name: "no rollout, 403 is muted", setup: func(h *home) { h.auth(authFile(ptr("acc"), "t")) },
			responses: map[string]any{"acc": domain.HTTPError{Status: 403}},
			status:    domain.StatusUnauthenticated, noData: true, whamCalls: 1,
		},
		{
			name: "no rollout, 429 throws", setup: func(h *home) { h.auth(authFile(ptr("acc"), "t")) },
			responses: map[string]any{"acc": domain.HTTPError{Status: 429}},
			wantErr:   true, whamCalls: 1,
		},
		{
			name: "no rollout, 500 throws", setup: func(h *home) { h.auth(authFile(ptr("acc"), "t")) },
			responses: map[string]any{"acc": domain.HTTPError{Status: 500}},
			wantErr:   true, whamCalls: 1,
		},
		{
			name: "no rollout, malformed 200 throws", setup: func(h *home) { h.auth(authFile(ptr("acc"), "t")) },
			responses: map[string]any{"acc": `{"rate_limit":3}`},
			wantErr:   true, whamCalls: 1,
		},
		{
			name: "rollout windows win without calling wham",
			setup: func(h *home) {
				h.auth(authFile(ptr("acc"), "t"))
				h.rollout("2026-10-07", "r.jsonl", tokenLine("2026-10-07T02:00:00.000Z", 120, liveWindows))
			},
			status: domain.StatusOK, source: "rollout", tokens: ip(120), quota: fp(0.60),
		},
		{
			name: "CLIProxy null windows overlay wham and keep rollout tokens",
			setup: func(h *home) {
				h.auth(authFile(ptr("acc"), "t"))
				h.rollout("2026-10-07", "r.jsonl", tokenLine("2026-10-07T02:00:00.000Z", 18404, windowless))
			},
			responses: map[string]any{"acc": usageBody("team", 11, 9)},
			status:    domain.StatusOK, source: "rollout+wham-usage", tokens: ip(18404), quota: fp(0.11), whamCalls: 1,
		},
		{
			name: "failed overlay leaves the rollout row with no bar",
			setup: func(h *home) {
				h.auth(authFile(ptr("acc"), "t"))
				h.rollout("2026-10-07", "r.jsonl", tokenLine("2026-10-07T02:00:00.000Z", 18404, windowless))
			},
			responses: map[string]any{"acc": domain.HTTPError{Status: 500}},
			status:    domain.StatusOK, source: "rollout", tokens: ip(18404), whamCalls: 1,
		},
		{
			name: "overlay with no quota in the response leaves the rollout row",
			setup: func(h *home) {
				h.auth(authFile(ptr("acc"), "t"))
				h.rollout("2026-10-07", "r.jsonl", tokenLine("2026-10-07T02:00:00.000Z", 18404, windowless))
			},
			responses: map[string]any{"acc": `{}`},
			status:    domain.StatusOK, source: "rollout", tokens: ip(18404), whamCalls: 1,
		},
		{
			name: "one login, overlay uses that login's token over auth.json",
			setup: func(h *home) {
				h.proxy(oneLoginFile, "aaaaaaaa-1", "proxy-token", "a@example.com")
				h.auth(authFile(ptr("aaaaaaaa-1"), "auth-token"))
				h.rollout("2026-10-07", "r.jsonl", tokenLine("2026-10-07T02:00:00.000Z", 5, windowless))
			},
			responses: map[string]any{"aaaaaaaa-1": usageBody("plus", 30, 5)},
			status:    domain.StatusOK, source: "rollout+wham-usage", tokens: ip(5), quota: fp(0.30), whamCalls: 1, wantToken: "proxy-token", wantHeader: ptr("aaaaaaaa-1"),
		},
		{
			name:      "one login without account id omits the header",
			setup:     func(h *home) { h.auth(authFile(nil, "solo")) },
			responses: map[string]any{"": usageBody("free", 12, 0)},
			status:    domain.StatusOK, source: "oauth-wham-usage", quota: fp(0.12), whamCalls: 1, wantToken: "solo",
		},
		{
			name:      "api key auth calls wham with the key and no account header",
			setup:     func(h *home) { h.auth(`{"OPENAI_API_KEY":"key"}`) },
			responses: map[string]any{"": domain.HTTPError{Status: 401}},
			status:    domain.StatusUnauthenticated, noData: true, whamCalls: 1, wantToken: "key",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h := newHome(t)
			h.http.responses = tc.responses
			tc.setup(h)
			p := h.build()
			snap, err := p.Fetch(context.Background(), testNow)
			if len(h.http.calls) != tc.whamCalls {
				t.Fatalf("wham calls = %d, want %d", len(h.http.calls), tc.whamCalls)
			}
			if tc.wantToken != "" && h.http.calls[0].token != tc.wantToken {
				t.Fatalf("wrong bearer sent")
			}
			if tc.whamCalls > 0 && tc.wantToken != "" {
				got := h.http.calls[0].accountID
				if (got == nil) != (tc.wantHeader == nil) || (got != nil && *got != *tc.wantHeader) {
					t.Fatalf("account header = %v", got)
				}
			}
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if p.Status().Kind != tc.status {
				t.Fatalf("status = %v", p.Status().Kind)
			}
			if snap.Accounts != nil {
				t.Fatalf("accounts must stay nil below two logins")
			}
			if tc.noData {
				if snap.Raw["status"] != "no-data-yet" || snap.TokensToday != nil || snap.Quota != nil || snap.QuotaWindows != nil {
					t.Fatalf("not muted: %+v", snap)
				}
				return
			}
			if snap.Raw["source"] != tc.source {
				t.Fatalf("source = %v", snap.Raw)
			}
			if (snap.TokensToday == nil) != (tc.tokens == nil) || (tc.tokens != nil && *snap.TokensToday != *tc.tokens) {
				t.Fatalf("tokens = %v", snap.TokensToday)
			}
			if tc.quota == nil {
				if snap.Quota != nil || snap.QuotaWindows != nil {
					t.Fatalf("unexpected quota %+v", snap.Quota)
				}
			} else {
				closeTo(t, snap.Quota, *tc.quota)
			}
		})
	}
}

func fp(f float64) *float64 { return &f }
func ip(i int) *int         { return &i }

func TestMultipleLogins(t *testing.T) {
	const plusID, teamID = "aaaaaaaa-plus", "bbbbbbbb-team"
	setup := func(h *home) {
		h.proxy("codex-aaaaaaaa-a@example.com-plus.json", plusID, "test-token-plus", "a@example.com")
		h.proxy("codex-bbbbbbbb-b@example.com-team.json", teamID, "test-token-team", "b@example.com")
		h.rollout("2026-10-07", "r.jsonl", tokenLine("2026-10-07T02:00:00.000Z", 18404, windowless))
	}
	account := func(t *testing.T, snap domain.UsageSnapshot, name string) domain.AccountUsage {
		t.Helper()
		for _, a := range snap.Accounts {
			if a.Name == name {
				return a
			}
		}
		t.Fatalf("no account %s in %+v", name, snap.Accounts)
		return domain.AccountUsage{}
	}
	check := func(t *testing.T, h *home, p provider.Provider, snap domain.UsageSnapshot) {
		t.Helper()
		if p.Status().Kind != domain.StatusOK || snap.Raw["source"] != "codex-accounts" || snap.QuotaWindows != nil {
			t.Fatalf("header: status %v raw %v windows %v", p.Status().Kind, snap.Raw, snap.QuotaWindows)
		}
		if *snap.TokensToday != 18404 || snap.CostTodayUSD == nil {
			t.Fatalf("header tokens/cost must stay the rollout's")
		}
		if len(h.http.calls) != 2 {
			t.Fatalf("calls = %d", len(h.http.calls))
		}
		if strings.Contains(fmt.Sprintf("%+v", snap), "test-token") {
			t.Fatal("token reached the snapshot")
		}
		for _, a := range snap.Accounts {
			if a.CostTodayUSD != nil {
				t.Fatalf("child cost must be nil")
			}
		}
	}

	t.Run("children take their own primary and header takes the max", func(t *testing.T) {
		h := newHome(t)
		setup(h)
		h.http.responses = map[string]any{plusID: usageBody("plus", 20, 90), teamID: usageBody("team", 70, 10)}
		p := h.build()
		snap, err := p.Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		check(t, h, p, snap)
		if snap.Accounts[0].Name != "plus" || snap.Accounts[1].Name != "team" {
			t.Fatalf("order = %+v", snap.Accounts)
		}
		closeTo(t, snap.Quota, 0.70)
		plus := account(t, snap, "plus")
		closeTo(t, plus.Quota, 0.20)
		if len(plus.QuotaWindows) != 2 || *plus.QuotaWindows[0].Duration != 18000 || *plus.QuotaWindows[1].Duration != 604800 || plus.QuotaWindows[0].ResetsAt.Unix() != 1800000000 {
			t.Fatalf("windows = %+v", plus.QuotaWindows)
		}
		if math.Abs(*plus.QuotaWindows[1].Utilization-0.90) > 1e-9 {
			t.Fatalf("secondary = %v", *plus.QuotaWindows[1].Utilization)
		}
	})

	t.Run("one failure keeps the other row and does not throw", func(t *testing.T) {
		h := newHome(t)
		setup(h)
		h.http.responses = map[string]any{plusID: usageBody("plus", 20, 90), teamID: domain.HTTPError{Status: 429}}
		p := h.build()
		snap, err := p.Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		check(t, h, p, snap)
		closeTo(t, snap.Quota, 0.20)
		team := account(t, snap, "team")
		if team.Quota != nil || team.QuotaWindows != nil {
			t.Fatalf("failed child = %+v", team)
		}
	})

	t.Run("missing primary does not use secondary", func(t *testing.T) {
		h := newHome(t)
		setup(h)
		h.http.responses = map[string]any{
			plusID: usageBody("plus", 40, 5),
			teamID: `{"plan_type":"team","rate_limit":{"secondary_window":{"used_percent":80,"reset_at":1900000000,"limit_window_seconds":604800}}}`,
		}
		p := h.build()
		snap, err := p.Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		closeTo(t, snap.Quota, 0.40)
		team := account(t, snap, "team")
		if team.Quota != nil || len(team.QuotaWindows) != 1 || team.QuotaWindows[0].Name != "secondary" {
			t.Fatalf("team = %+v", team)
		}
	})

	t.Run("no primary fraction leaves header quota nil", func(t *testing.T) {
		h := newHome(t)
		setup(h)
		h.http.responses = map[string]any{plusID: `{}`, teamID: domain.HTTPError{Status: 500}}
		snap, err := h.build().Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		if snap.Quota != nil {
			t.Fatalf("quota = %+v", snap.Quota)
		}
	})

	t.Run("live rollout windows do not replace per-login wham", func(t *testing.T) {
		h := newHome(t)
		setup(h)
		h.rollout("2026-10-07", "r.jsonl", tokenLine("2026-10-07T02:00:00.000Z", 18404, liveWindows))
		h.http.responses = map[string]any{plusID: usageBody("plus", 22, 1), teamID: usageBody("team", 2, 3)}
		p := h.build()
		snap, err := p.Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		check(t, h, p, snap)
		closeTo(t, snap.Quota, 0.22)
	})

	t.Run("auth.json label uses wham plan_type", func(t *testing.T) {
		h := newHome(t)
		h.proxy("codex-aaaaaaaa-a@example.com-plus.json", plusID, "test-token-plus", "a@example.com")
		h.auth(authFile(ptr("cccccccc-pro"), "test-token-pro"))
		h.http.responses = map[string]any{plusID: usageBody("plus", 10, 0), "cccccccc-pro": usageBody("Pro", 30, 0)}
		snap, err := h.build().Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		if snap.Accounts[0].Name != "plus" || snap.Accounts[1].Name != "pro" {
			t.Fatalf("names = %+v", snap.Accounts)
		}
		closeTo(t, account(t, snap, "pro").Quota, 0.30)
	})
}

func TestOffsets(t *testing.T) {
	h := newHome(t)
	path := h.rollout("2026-10-07", "r.jsonl", tokenLine("2026-10-07T02:00:00.000Z", 1, "")+"\npartial")
	yesterday := h.rollout("2026-10-06", "y.jsonl", tokenLine("2026-10-06T02:00:00.000Z", 1, "")+"\n")
	p := h.build()
	if _, err := p.Fetch(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	if h.c.writes != 1 || len(h.c.offsets) != 2 {
		t.Fatalf("writes %d offsets %d", h.c.writes, len(h.c.offsets))
	}
	canonical, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	key := "file://" + canonical
	got, ok := h.c.offsets[key]
	if !ok {
		t.Fatalf("keys = %v", h.c.offsets)
	}
	full, _ := os.ReadFile(path)
	if want := uint64(len(full) - len("partial")); got.ByteOffset != want {
		t.Fatalf("offset = %d, want %d: a partial line is not consumed", got.ByteOffset, want)
	}
	canonicalY, _ := filepath.EvalSymlinks(yesterday)
	if _, ok := h.c.offsets["file://"+canonicalY]; !ok {
		t.Fatal("yesterday's file not tracked")
	}
	if _, err := p.Fetch(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	if h.c.writes != 2 {
		t.Fatalf("each fetch makes one batched write, got %d", h.c.writes)
	}
}

func TestOffsetKeyEscapesLikeURLAbsoluteString(t *testing.T) {
	if got := offsetKey("/Users/a b/.codex/r.jsonl"); got != "file:///Users/a%20b/.codex/r.jsonl" {
		t.Fatalf("key = %s", got)
	}
}

func TestFetchNeverWritesCredentials(t *testing.T) {
	h := newHome(t)
	h.auth(authFile(ptr("acc"), "t"))
	h.proxy("codex-aaaaaaaa-a@example.com-plus.json", "a", "t2", "a@example.com")
	h.http.responses = map[string]any{"acc": domain.HTTPError{Status: 401}, "a": domain.HTTPError{Status: 401}}
	before := treeSums(t, h.root)
	if _, err := h.build().Fetch(context.Background(), testNow); err != nil {
		t.Fatal(err)
	}
	after := treeSums(t, h.root)
	if fmt.Sprint(before) != fmt.Sprint(after) {
		t.Fatal("a credential file changed")
	}
}

func treeSums(t *testing.T, root string) map[string][32]byte {
	t.Helper()
	sums := map[string][32]byte{}
	if err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		data, err := os.ReadFile(path)
		sums[path] = sha256.Sum256(data)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	return sums
}
