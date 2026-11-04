package claude

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

func writeSession(t *testing.T, dir, name, body string, mtime time.Time) string {
	t.Helper()
	path := filepath.Join(dir, name+".json")
	writeFile(t, path, body)
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	return path
}

func costJSON(id string, usd float64) string {
	return fmt.Sprintf(`{"session_id":%q,"cost":{"total_cost_usd":%v}}`, id, usd)
}

func quotaJSON(id string, five, seven, resets float64) string {
	return fmt.Sprintf(`{"session_id":%q,"cost":{"total_cost_usd":0},"rate_limits":{"five_hour":{"used_percentage":%v,"resets_at":%v},"seven_day":{"used_percentage":%v,"resets_at":%v}}}`, id, five, resets, seven, resets)
}

func newHook(dir string) *hookFeed {
	return &hookFeed{dir: dir, dayKeys: testDayKeys()}
}

func fetchHook(t *testing.T, dir string) domain.UsageSnapshot {
	t.Helper()
	snap, err := newHook(dir).fetch(testNow)
	if err != nil {
		t.Fatal(err)
	}
	return snap
}

var earlierToday = testNow.Add(-time.Hour)

func TestHookPayloadDecoding(t *testing.T) {
	var full hookPayload
	body := `{"session_id":"s","transcript_path":"/u/.claude/projects/p/s.jsonl","model":{"id":"m","display_name":"M"},"cost":{"total_cost_usd":1.5},"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1767225600},"seven_day":null}}`
	if err := json.Unmarshal([]byte(body), &full); err != nil {
		t.Fatal(err)
	}
	if *full.SessionID != "s" || *full.Cost.TotalCostUSD != 1.5 || full.RateLimits.SevenDay != nil {
		t.Fatalf("%+v", full)
	}
	if got := full.RateLimits.FiveHour.resetsAtTime(); !got.Equal(time.Unix(1767225600, 0)) {
		t.Fatalf("%v", got)
	}
	var empty hookPayload
	if err := json.Unmarshal([]byte(`{}`), &empty); err != nil || empty.SessionID != nil || empty.RateLimits != nil {
		t.Fatalf("%v %+v", err, empty)
	}
	var nulled hookPayload
	if err := json.Unmarshal([]byte(`{"rate_limits":{"five_hour":{"used_percentage":null,"resets_at":null}}}`), &nulled); err != nil || nulled.RateLimits.FiveHour.UsedPercentage != nil {
		t.Fatalf("%v %+v", err, nulled)
	}
	var wrong hookPayload
	if json.Unmarshal([]byte(`{"cost":{"total_cost_usd":"1"}}`), &wrong) == nil {
		t.Fatal("a wrong-typed field rejects the payload, as Codable does")
	}
}

func TestHookCost(t *testing.T) {
	t.Run("sums sessions touched today", func(t *testing.T) {
		dir := t.TempDir()
		writeSession(t, dir, "a", costJSON("a", 1.5), earlierToday)
		writeSession(t, dir, "b", costJSON("b", 2.25), earlierToday)
		snap := fetchHook(t, dir)
		if snap.CostTodayUSD.Cmp(decimal.MustParse("3.75")) != 0 || snap.TokensToday != nil {
			t.Fatalf("%+v", snap)
		}
	})
	t.Run("excludes yesterday's mtime", func(t *testing.T) {
		dir := t.TempDir()
		writeSession(t, dir, "a", costJSON("a", 1), earlierToday)
		writeSession(t, dir, "old", costJSON("old", 100), testNow.Add(-13*time.Hour))
		if snap := fetchHook(t, dir); snap.CostTodayUSD.Cmp(decimal.MustParse("1")) != 0 {
			t.Fatalf("%v", snap.CostTodayUSD)
		}
	})
	t.Run("rounds through six digits", func(t *testing.T) {
		if got := decimalFromUSD(0.1 + 0.2).String(); got != "0.3" {
			t.Fatal(got)
		}
	})
}

func TestHookWindows(t *testing.T) {
	t.Run("same reset keeps the peak", func(t *testing.T) {
		dir := t.TempDir()
		writeSession(t, dir, "a", quotaJSON("a", 100, 10, 2000), earlierToday)
		writeSession(t, dir, "b", quotaJSON("b", 86, 5, 2000), earlierToday.Add(time.Minute))
		snap := fetchHook(t, dir)
		if *snap.QuotaWindows[0].Utilization != 1 || *snap.QuotaWindows[1].Utilization != 0.1 || snap.Quota.Used != 1 {
			t.Fatalf("%+v", snap)
		}
	})
	t.Run("a later reset replaces", func(t *testing.T) {
		dir := t.TempDir()
		writeSession(t, dir, "a", quotaJSON("a", 100, 10, 2000), earlierToday)
		writeSession(t, dir, "b", quotaJSON("b", 3, 2, 3000), earlierToday.Add(time.Minute))
		if snap := fetchHook(t, dir); *snap.QuotaWindows[0].Utilization != 0.03 {
			t.Fatalf("%+v", snap.QuotaWindows)
		}
	})
	t.Run("a payload without the window keeps the peak", func(t *testing.T) {
		dir := t.TempDir()
		writeSession(t, dir, "a", quotaJSON("a", 77, 10, 2000), earlierToday)
		writeSession(t, dir, "b", `{"session_id":"b","rate_limits":{"seven_day":{"used_percentage":11,"resets_at":2000}}}`, earlierToday.Add(time.Minute))
		snap := fetchHook(t, dir)
		if *snap.QuotaWindows[0].Utilization != 0.77 || *snap.QuotaWindows[1].Utilization != 0.11 {
			t.Fatalf("%+v", snap.QuotaWindows)
		}
	})
}

func TestHookFeedStates(t *testing.T) {
	for name, dir := range map[string]string{"empty": t.TempDir(), "missing": filepath.Join(t.TempDir(), "none")} {
		t.Run(name, func(t *testing.T) {
			h := newHook(dir)
			if _, err := h.fetch(testNow); !errors.Is(err, errNoFeedData) {
				t.Fatal(err)
			}
		})
	}
	t.Run("stale newest yields a zero snapshot, not an error", func(t *testing.T) {
		dir := t.TempDir()
		writeSession(t, dir, "a", quotaJSON("a", 90, 90, 2000), testNow.Add(-30*time.Hour))
		h := newHook(dir)
		snap, err := h.fetch(testNow)
		if err != nil {
			t.Fatal(err)
		}
		if !snap.CostTodayUSD.IsZero() || snap.Quota != nil || snap.QuotaWindows != nil || snap.Accounts != nil {
			t.Fatalf("%+v", snap)
		}
	})
}

func TestHookMultiAccount(t *testing.T) {
	dir := t.TempDir()
	writeSession(t, dir, "d", quotaJSON("d", 10, 20, 2000), earlierToday)
	writeSession(t, filepath.Join(dir, "work"), "w", `{"session_id":"w","cost":{"total_cost_usd":2},"rate_limits":{"five_hour":{"used_percentage":50,"resets_at":2000},"seven_day":{"used_percentage":40,"resets_at":2000}}}`, earlierToday)
	writeSession(t, filepath.Join(dir, "personal"), "p", `{"session_id":"p","cost":{"total_cost_usd":1.5}}`, earlierToday)
	snap := fetchHook(t, dir)

	names := make([]string, 0, len(snap.Accounts))
	for _, a := range snap.Accounts {
		names = append(names, a.Name)
	}
	if strings.Join(names, ",") != "default,personal,work" {
		t.Fatalf("default first, then alphabetical: %v", names)
	}
	windows := make([]string, 0, len(snap.QuotaWindows))
	for _, w := range snap.QuotaWindows {
		windows = append(windows, w.Name)
	}
	if strings.Join(windows, ",") != "default 5h,default 7d,work 5h,work 7d" {
		t.Fatalf("%v", windows)
	}
	if snap.Quota.Used != 0.5 {
		t.Fatalf("primary is the worst account: %+v", snap.Quota)
	}
	if snap.CostTodayUSD.Cmp(decimal.MustParse("3.5")) != 0 {
		t.Fatalf("%v", snap.CostTodayUSD)
	}
	if snap.Raw["quota.work"] != "50%" || snap.Raw["cost.work"] != "2" || snap.Raw["cost.personal"] != "1.5" {
		t.Fatalf("%v", snap.Raw)
	}
	work := snap.Accounts[2]
	if work.QuotaWindows[0].Name != "5h" || work.Quota.Used != 0.5 || work.CostTodayUSD.String() != "2" {
		t.Fatalf("account windows keep plain names: %+v", work)
	}
	if personal := snap.Accounts[1]; personal.Quota != nil || personal.QuotaWindows != nil {
		t.Fatalf("%+v", personal)
	}
}

func TestHookAttribution(t *testing.T) {
	t.Run("duplicate session across accounts: newest copy wins", func(t *testing.T) {
		dir := t.TempDir()
		writeSession(t, filepath.Join(dir, "work"), "s", costJSON("s", 5), earlierToday)
		writeSession(t, filepath.Join(dir, "personal"), "s", costJSON("s", 9), earlierToday.Add(time.Minute))
		snap := fetchHook(t, dir)
		if snap.CostTodayUSD.Cmp(decimal.MustParse("9")) != 0 || len(snap.Accounts) != 1 || snap.Accounts[0].Name != "personal" {
			t.Fatalf("%+v", snap)
		}
	})
	t.Run("transcript_path beats the directory", func(t *testing.T) {
		dir := t.TempDir()
		writeSession(t, filepath.Join(dir, "work"), "s", `{"session_id":"s","transcript_path":"/u/.ccs/instances/personal/projects/p/s.jsonl","cost":{"total_cost_usd":1}}`, earlierToday)
		if snap := fetchHook(t, dir); snap.Accounts[0].Name != "personal" {
			t.Fatalf("%+v", snap.Accounts)
		}
	})
	t.Run("single account keeps plain window names", func(t *testing.T) {
		dir := t.TempDir()
		writeSession(t, dir, "a", quotaJSON("a", 10, 10, 2000), earlierToday)
		if snap := fetchHook(t, dir); snap.QuotaWindows[0].Name != "5h" {
			t.Fatalf("%+v", snap.QuotaWindows)
		}
	})
	paths := map[string]string{
		"/u/.ccs/instances/work/projects/p/s.jsonl": "work",
		"/u/.claude/projects/p/s.jsonl":             "default",
		"/somewhere/else.jsonl":                     "",
		"/u/.ccs/instances//x":                      "",
	}
	for path, want := range paths {
		got := accountFromTranscriptPath(&path)
		if (want == "" && got != nil) || (want != "" && (got == nil || *got != want)) {
			t.Errorf("%s: %v", path, got)
		}
	}
	if accountFromTranscriptPath(nil) != nil {
		t.Error("nil path")
	}
}

func TestHookCleanup(t *testing.T) {
	dir := t.TempDir()
	fresh := writeSession(t, dir, "fresh", costJSON("fresh", 1), earlierToday)
	old := writeSession(t, dir, "old", costJSON("old", 1), testNow.Add(-49*time.Hour))
	oldSub := writeSession(t, filepath.Join(dir, "work"), "older", costJSON("older", 1), testNow.Add(-72*time.Hour))
	newHook(dir).prune(testNow)
	if _, err := os.Stat(fresh); err != nil {
		t.Fatal("fresh removed")
	}
	for _, path := range []string{old, oldSub} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("%s kept", path)
		}
	}
	fetched := writeSession(t, dir, "old2", costJSON("old2", 1), testNow.Add(-49*time.Hour))
	fetchHook(t, dir)
	if _, err := os.Stat(fetched); !os.IsNotExist(err) {
		t.Fatal("fetch must also clean")
	}
}

func TestSessionAccounts(t *testing.T) {
	dir := t.TempDir()
	writeSession(t, dir, "s1", `{"session_id":"s1","transcript_path":"/u/.ccs/instances/personal/projects/p/s1.jsonl"}`, earlierToday)
	writeSession(t, filepath.Join(dir, "work"), "s2", `{"session_id":"s2"}`, earlierToday)
	writeSession(t, dir, "bad", `{not json`, earlierToday)
	writeSession(t, filepath.Join(dir, "work"), "s3", `{"session_id":"s3"}`, earlierToday)
	writeSession(t, filepath.Join(dir, "personal"), "s3", `{"session_id":"s3"}`, earlierToday.Add(time.Minute))
	writeSession(t, dir, "old", `{"session_id":"old"}`, testNow.Add(-20*time.Hour))
	h := newHook(dir)
	got := h.sessionAccounts(nil)
	want := map[string]string{"s1": "personal", "s2": "work", "s3": "personal", "old": "default"}
	if len(got) != len(want) {
		t.Fatalf("%v", got)
	}
	for session, owner := range want {
		if got[session] != owner {
			t.Errorf("%s: %s", session, got[session])
		}
	}
	today := testNow.Add(-12 * time.Hour)
	if _, kept := h.sessionAccounts(&today)["old"]; kept {
		t.Fatal("since must drop old sessions")
	}
}

func facade(useHook bool, reads *sessionReads, dir string) *Provider {
	return &Provider{useHook: useHook, reads: reads, hook: newHook(dir)}
}

func TestSourceSwitch(t *testing.T) {
	root, feed := t.TempDir(), t.TempDir()
	writeFile(t, filepath.Join(root, "p", "s.jsonl"), assistantLine(todayStamp, "r1", "claude-test", 10, 0, 0, 0))
	writeSession(t, feed, "s", costJSON("s", 3), earlierToday)
	old := writeSession(t, feed, "old", costJSON("old", 1), testNow.Add(-49*time.Hour))

	reads := facade(false, newReads([]string{root}, nil, cache.Noop{}), feed)
	snap, status, err := reads.Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if *snap.TokensToday != 10 || snap.Accounts != nil || snap.CostTodayUSD.Float64() >= 3 || status.Kind != domain.StatusOK {
		t.Fatalf("session reads must answer: %+v", snap)
	}
	if _, err := os.Stat(old); !os.IsNotExist(err) {
		t.Fatal("session reads must prune the feed")
	}

	hook := facade(true, newReads([]string{root}, nil, cache.Noop{}), feed)
	snap, status, err = hook.Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if snap.CostTodayUSD.Cmp(decimal.MustParse("3")) != 0 || *snap.TokensToday != 10 || len(snap.Accounts) != 1 || status.Kind != domain.StatusOK {
		t.Fatalf("hook answers cost, the read grafts tokens: %+v", snap)
	}
}

func TestHookErrorStillAdvancesRead(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "s.jsonl"), assistantLine(todayStamp, "", "claude-test", 1, 0, 0, 0))
	store := newMemoryStore()
	p := facade(true, newReads([]string{root}, nil, store), filepath.Join(t.TempDir(), "none"))
	if _, _, err := p.Fetch(context.Background(), testNow); !errors.Is(err, errNoFeedData) {
		t.Fatal(err)
	}
	if len(store.offsets) != 1 {
		t.Fatal("the concurrent read in Swift has already persisted its cursors")
	}
}

func TestAccountTokens(t *testing.T) {
	line := func(request string, input int) string {
		return assistantLine(todayStamp, request, "claude-test", input, 0, 0, 0)
	}
	tokensOf := func(snap domain.UsageSnapshot) string {
		out := []string{}
		for _, a := range snap.Accounts {
			if a.TokensToday == nil {
				out = append(out, a.Name+"=nil")
			} else {
				out = append(out, fmt.Sprintf("%s=%d", a.Name, *a.TokensToday))
			}
		}
		return strings.Join(out, " ")
	}
	session := func(id, slug string) string {
		return fmt.Sprintf(`{"session_id":%q,"transcript_path":"/u/.ccs/instances/%s/projects/p/%s.jsonl","cost":{"total_cost_usd":1}}`, id, slug, id)
	}

	t.Run("each account gets its sessions, the rest stay unattributed", func(t *testing.T) {
		root, feed := t.TempDir(), t.TempDir()
		writeFile(t, filepath.Join(root, "p", "s1.jsonl"), line("r1", 100))
		writeFile(t, filepath.Join(root, "p", "s2", "subagents", "agent-a.jsonl"), line("r2", 30))
		writeFile(t, filepath.Join(root, "p", "s3.jsonl"), line("r3", 7))
		writeSession(t, feed, "s1", session("s1", "personal"), earlierToday)
		writeSession(t, feed, "s2", session("s2", "work"), earlierToday)
		snap, _, err := facade(true, newReads([]string{root}, nil, cache.Noop{}), feed).Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		if *snap.TokensToday != 137 || tokensOf(snap) != "personal=100 work=30" {
			t.Fatalf("%d %s", *snap.TokensToday, tokensOf(snap))
		}
	})

	t.Run("no session today is a known 0, a session today without tokens is unknown", func(t *testing.T) {
		root, feed := t.TempDir(), t.TempDir()
		writeFile(t, filepath.Join(root, "p", "s1.jsonl"), line("r1", 10))
		writeSession(t, feed, "s1", session("s1", "personal"), earlierToday)
		writeSession(t, feed, "s9", session("s9", "work"), testNow.Add(-13*time.Hour))
		writeSession(t, feed, "s8", session("s8", "team"), earlierToday)
		snap, _, err := facade(true, newReads([]string{root}, nil, cache.Noop{}), feed).Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		if got := tokensOf(snap); got != "personal=10 team=nil work=0" {
			t.Fatal(got)
		}
	})

	t.Run("no transcript root leaves tokens unknown, never 0", func(t *testing.T) {
		feed := t.TempDir()
		writeSession(t, feed, "s1", session("s1", "personal"), earlierToday)
		writeSession(t, feed, "s2", session("s2", "work"), earlierToday)
		reads := newReads([]string{filepath.Join(t.TempDir(), "none")}, nil, cache.Noop{})
		snap, _, err := facade(true, reads, feed).Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		if got := tokensOf(snap); got != "personal=nil work=nil" {
			t.Fatal(got)
		}
	})

	t.Run("a failed read leaves tokens nil and does not fail the fetch", func(t *testing.T) {
		if os.Geteuid() == 0 {
			t.Skip("root reads everything")
		}
		root, feed := t.TempDir(), t.TempDir()
		path := filepath.Join(root, "s.jsonl")
		writeFile(t, path, line("r", 1))
		if err := os.Chmod(path, 0); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = os.Chmod(path, 0o600) })
		writeSession(t, feed, "s1", session("s1", "work"), testNow.Add(-13*time.Hour))
		snap, _, err := facade(true, newReads([]string{root}, nil, cache.Noop{}), feed).Fetch(context.Background(), testNow)
		if err != nil {
			t.Fatal(err)
		}
		if snap.TokensToday != nil || tokensOf(snap) != "work=nil" {
			t.Fatalf("%v %s", snap.TokensToday, tokensOf(snap))
		}
	})
}

func TestEnumerateFeedFollowsSymlinkedFiles(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(t.TempDir(), "s.json")
	if err := os.WriteFile(target, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	account := filepath.Join(dir, "work")
	if err := os.Mkdir(account, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, link := range []string{filepath.Join(dir, "top.json"), filepath.Join(account, "nested.json")} {
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
	}
	entries, err := enumerateFeed(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 {
		t.Fatalf("got %d entries, want both symlinked files", len(entries))
	}
}
