package claude

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/jsonl"
)

const (
	todayStamp     = "2026-05-13T10:00:00.000Z"
	yesterdayStamp = "2026-05-12T10:00:00.000Z"
)

func fetchReads(t *testing.T, r *sessionReads) (domain.UsageSnapshot, map[string]int) {
	t.Helper()
	snap, sessions, err := r.fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	return snap, sessions
}

func TestNoSourceIsUnauthenticated(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing")
	r := newReads([]string{missing}, nil, cache.Noop{})
	snap, sessions := fetchReads(t, r)
	if snap.Raw[domain.RawProviderStatus] != domain.StatusSentinelUnauth || r.status.Kind != domain.StatusUnauthenticated || *snap.TokensToday != 0 || sessions != nil {
		t.Fatalf("%+v", snap)
	}
}

func TestRootCreatedAfterBuildIsRead(t *testing.T) {
	root := filepath.Join(t.TempDir(), "later")
	r := newReads([]string{root}, nil, cache.Noop{})
	fetchReads(t, r)
	if r.status.Kind != domain.StatusUnauthenticated {
		t.Fatal("no root yet")
	}
	writeFile(t, filepath.Join(root, "p", "s.jsonl"), assistantLine(todayStamp, "r1", "claude-test", 10, 0, 0, 0))
	snap, _ := fetchReads(t, r)
	if *snap.TokensToday != 10 || r.status.Kind != domain.StatusOK {
		t.Fatalf("%+v", snap)
	}
}

func TestEmptyRootIsZeroNotUnauthenticated(t *testing.T) {
	r := newReads([]string{t.TempDir()}, nil, cache.Noop{})
	snap, sessions := fetchReads(t, r)
	if *snap.TokensToday != 0 || r.status.Kind != domain.StatusOK || sessions == nil || snap.Raw[domain.RawProviderStatus] != "" {
		t.Fatalf("%+v %v", snap, sessions)
	}
}

func TestReadsAggregateAcrossFiles(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "p", "s1.jsonl"),
		assistantLine(todayStamp, "r1", "claude-test", 1000, 500, 0, 0)+
			assistantLine(yesterdayStamp, "r0", "claude-test", 99999, 0, 0, 0))
	writeFile(t, filepath.Join(root, "p", "s2", "subagents", "a.jsonl"),
		assistantLine(todayStamp, "r2", "claude-test", 20, 0, 0, 0)+
			assistantLine(todayStamp, "r1", "claude-test", 1000, 500, 0, 0))
	writeFile(t, filepath.Join(root, "p", "s3.jsonl"), assistantLine(todayStamp, "", "claude-test", 7, 0, 0, 0)+assistantLine(todayStamp, "", "claude-test", 7, 0, 0, 0))
	r := newReads([]string{root}, nil, cache.Noop{})
	snap, sessions := fetchReads(t, r)
	if *snap.TokensToday != 1534 {
		t.Fatalf("yesterday excluded, r1 deduped across files, no-id lines counted: %d", *snap.TokensToday)
	}
	if sessions["s1"] != 1500 || sessions["s2"] != 20 || sessions["s3"] != 14 {
		t.Fatalf("%v", sessions)
	}
	if snap.CostTodayUSD.Float64() <= 0 || snap.Quota != nil || snap.QuotaWindows != nil {
		t.Fatalf("%+v", snap)
	}
}

func TestSymlinkedInstanceRootCountsOnce(t *testing.T) {
	shared := t.TempDir()
	writeFile(t, filepath.Join(shared, "p", "s.jsonl"), assistantLine(todayStamp, "", "claude-test", 5, 0, 0, 0))
	link := filepath.Join(t.TempDir(), "projects")
	if err := os.Symlink(shared, link); err != nil {
		t.Fatal(err)
	}
	snap, _ := fetchReads(t, newReads([]string{shared, link}, nil, cache.Noop{}))
	if *snap.TokensToday != 5 {
		t.Fatalf("a line with no request ID must not count per root: %d", *snap.TokensToday)
	}
}

func TestSecondPollReadsOnlyTheDelta(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "p", "s.jsonl")
	writeFile(t, path, assistantLine(todayStamp, "r1", "claude-test", 10, 0, 0, 0))
	store := newMemoryStore()
	r := newReads([]string{root}, nil, store)
	if snap, _ := fetchReads(t, r); *snap.TokensToday != 10 {
		t.Fatalf("%d", *snap.TokensToday)
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatal(err)
	}
	offset, ok := store.offsets[jsonl.FileURL(resolved)]
	if !ok || offset.ByteOffset == 0 {
		t.Fatalf("cursor not persisted under its file URL: %v", store.offsets)
	}
	if snap, _ := fetchReads(t, r); *snap.TokensToday != 0 {
		t.Fatalf("nothing new, got %d", *snap.TokensToday)
	}
	appended := assistantLine(todayStamp, "r1", "claude-test", 10, 0, 0, 0) + assistantLine(todayStamp, "r2", "claude-test", 3, 0, 0, 0)
	writeFile(t, path, appended)
	if err := os.Chtimes(path, time.Time{}, time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	if snap, _ := fetchReads(t, r); *snap.TokensToday != 3 {
		t.Fatalf("delta only, got %d", *snap.TokensToday)
	}
}

func TestUnreadableTranscriptFailsAndKeepsCursors(t *testing.T) {
	root := t.TempDir()
	writeFile(t, filepath.Join(root, "s.jsonl"), assistantLine(todayStamp, "", "claude-test", 1, 0, 0, 0))
	if err := os.Chmod(filepath.Join(root, "s.jsonl"), 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(filepath.Join(root, "s.jsonl"), 0o600) })
	if os.Geteuid() == 0 {
		t.Skip("root reads everything")
	}
	store := newMemoryStore()
	r := newReads([]string{root}, nil, store)
	if _, _, err := r.fetch(context.Background(), testNow); err == nil {
		t.Fatal("want error")
	}
	if r.status.Kind != domain.StatusError || len(store.offsets) != 0 {
		t.Fatalf("%+v %v", r.status, store.offsets)
	}
}

func TestOAuthQuota(t *testing.T) {
	pct := func(v float64) *float64 { return &v }
	stamp := "2026-05-13T20:00:00.000+00:00"
	full := &usageResponse{
		FiveHour:       &quotaWindowResponse{pct(67.5), &stamp},
		SevenDay:       &quotaWindowResponse{pct(80), &stamp},
		SevenDaySonnet: &quotaWindowResponse{pct(99), nil},
		SevenDayOpus:   &quotaWindowResponse{nil, nil},
	}
	r := newReads([]string{t.TempDir()}, fakeUsage{response: full}, cache.Noop{})
	snap, _ := fetchReads(t, r)
	names := ""
	for _, w := range snap.QuotaWindows {
		names += w.Name + ","
	}
	if names != "5h,7d,7d-sonnet,7d-opus," {
		t.Fatal(names)
	}
	if *snap.QuotaWindows[0].Utilization != 0.675 || snap.QuotaWindows[0].ResetsAt == nil || snap.QuotaWindows[3].Utilization != nil {
		t.Fatalf("%+v", snap.QuotaWindows)
	}
	if snap.Quota.Used != 0.8 || snap.Quota.Limit != 1 {
		t.Fatalf("primary is max of 5h and 7d, without per-model windows: %+v", snap.Quota)
	}

	degraded := newReads([]string{t.TempDir()}, fakeUsage{err: errors.New("429")}, cache.Noop{})
	snap, _ = fetchReads(t, degraded)
	if snap.QuotaWindows != nil || snap.Quota != nil || degraded.status.Kind != domain.StatusOK {
		t.Fatalf("OAuth failure degrades to local only: %+v", snap)
	}

	onlyOAuth := newReads([]string{filepath.Join(t.TempDir(), "missing")}, fakeUsage{response: full}, cache.Noop{})
	snap, _ = fetchReads(t, onlyOAuth)
	if onlyOAuth.status.Kind != domain.StatusOK || len(snap.QuotaWindows) != 4 || *snap.TokensToday != 0 {
		t.Fatalf("OAuth with no transcripts: %+v", snap)
	}

	empty := newReads([]string{t.TempDir()}, fakeUsage{response: &usageResponse{}}, cache.Noop{})
	snap, _ = fetchReads(t, empty)
	if snap.QuotaWindows != nil || snap.Quota != nil {
		t.Fatalf("%+v", snap)
	}
}
