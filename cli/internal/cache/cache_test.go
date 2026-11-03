package cache

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

var (
	day1 = time.Date(2026, 3, 14, 12, 0, 0, 0, time.UTC)
	day2 = day1.Add(24 * time.Hour)
)

func newStore(t *testing.T) (*File, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "sub", "today.json")
	return NewFile(path, domain.NewDayKeyOwner(clock.Fixed(day1), time.UTC)), path
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

const state = `{"id":"claude","displayName":"Claude","status":{"unauthenticated":{}}}`

func TestFreshStoreIsEmptyAndCreatesNothing(t *testing.T) {
	s, path := newStore(t)
	if len(s.LoadAll()) != 0 || len(s.AllTranscriptOffsets()) != 0 || s.Baseline(domain.Claude) != nil {
		t.Error("not empty")
	}
	if _, err := os.Stat(filepath.Dir(path)); err == nil {
		t.Error("a read created the directory")
	}
}

func TestLoadsEverySchemaVersion(t *testing.T) {
	cases := []struct {
		name, body string
		rows       int
	}{
		{"v3", `{"schemaVersion":3,"providers":["claude",` + state + `],"baselines":[],"transcripts":{},"dailyUsage":[]}`, 1},
		{"v2", `{"schemaVersion":2,"providers":["claude",` + state + `],"baselines":[],"transcripts":{}}`, 1},
		{"v1", `{"schemaVersion":1,"providers":["claude",` + state + `],"baselines":[]}`, 1},
		{"v3 missing a section", `{"schemaVersion":3,"providers":["claude",` + state + `],"baselines":[],"transcripts":{}}`, 0},
		{"unknown version", `{"schemaVersion":99,"providers":["claude",` + state + `],"baselines":[],"transcripts":{},"dailyUsage":[]}`, 0},
		{"malformed", `{not json`, 0},
		{"odd pair list", `{"schemaVersion":1,"providers":["claude"],"baselines":[]}`, 0},
		{"bad row fails the whole cache", `{"schemaVersion":1,"providers":["claude",` + state + `,"codex",{"id":"codex"}],"baselines":[]}`, 0},
	}
	for _, c := range cases {
		s, path := newStore(t)
		write(t, path, c.body)
		if got := len(s.LoadAll()); got != c.rows {
			t.Errorf("%s: %d rows", c.name, got)
		}
	}
}

func TestBaselineRules(t *testing.T) {
	s, _ := newStore(t)
	s.MaintainBaseline(domain.OpenRouter, day1, 10)
	b := s.Baseline(domain.OpenRouter)
	if b.Value != 10 || b.LastValue != 10 || b.Date != "2026-03-14" {
		t.Errorf("cold start: %+v", b)
	}
	s.MaintainBaseline(domain.OpenRouter, day1, 15)
	if b = s.Baseline(domain.OpenRouter); b.Value != 10 || b.LastValue != 15 {
		t.Errorf("same day: %+v", b)
	}
	s.MaintainBaseline(domain.OpenRouter, day1, 7)
	if b = s.Baseline(domain.OpenRouter); b.Value != 7 || b.LastValue != 7 {
		t.Errorf("negative delta: %+v", b)
	}
	s.MaintainBaseline(domain.OpenRouter, day2, 20)
	if b = s.Baseline(domain.OpenRouter); b.Value != 20 || b.Date != "2026-03-15" {
		t.Errorf("next day: %+v", b)
	}
}

func TestAccumulateDailyUsage(t *testing.T) {
	s, path := newStore(t)
	one := decimal.MustParse("0.1")
	got := s.AccumulateDailyUsage(domain.Claude, day1, 5, one, map[string]int{"a": 2})
	if got.Tokens != 5 || got.CostUSD.String() != "0.1" {
		t.Errorf("%+v", got)
	}
	got = s.AccumulateDailyUsage(domain.Claude, day1, 3, decimal.MustParse("0.2"), map[string]int{"a": 1, "b": 4})
	if got.Tokens != 8 || got.CostUSD.String() != "0.3" || got.SessionTokens["a"] != 3 || got.SessionTokens["b"] != 4 {
		t.Errorf("sum: %+v", got)
	}
	other := s.AccumulateDailyUsage(domain.Codex, day1, 1, one, nil)
	if other.Tokens != 1 {
		t.Errorf("providers are isolated: %+v", other)
	}
	fresh := NewFile(path, domain.NewDayKeyOwner(clock.Fixed(day1), time.UTC))
	got = fresh.AccumulateDailyUsage(domain.Claude, day1, 1, one, nil)
	if got.Tokens != 9 || got.CostUSD.String() != "0.4" {
		t.Errorf("persisted: %+v", got)
	}
	got = fresh.AccumulateDailyUsage(domain.Claude, day2, 2, one, map[string]int{"c": 1})
	if got.Tokens != 2 || got.CostUSD.String() != "0.1" || got.SessionTokens["a"] != 0 {
		t.Errorf("rollover: %+v", got)
	}
}

func TestOldCacheWithoutSessionTokensReadsEmpty(t *testing.T) {
	s, path := newStore(t)
	write(t, path, `{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":["claude",{"date":"2026-03-14","tokens":5,"costUSD":1.5}]}`)
	got := s.AccumulateDailyUsage(domain.Claude, day1, 1, decimal.MustParse("0.5"), nil)
	if got.Tokens != 6 || got.CostUSD.String() != "2" {
		t.Errorf("%+v", got)
	}
}

func TestTranscriptOffsets(t *testing.T) {
	s, _ := newStore(t)
	mod := time.Date(2026, 3, 14, 1, 2, 3, 500_000_000, time.UTC)
	s.SetTranscriptOffsets([]domain.TranscriptOffset{{URL: "/a/b.jsonl", ByteOffset: 10, LastModified: mod}, {URL: "/c.jsonl", ByteOffset: 20, LastModified: mod}})
	got := s.TranscriptOffset("/a/b.jsonl")
	if got == nil || got.ByteOffset != 10 || !got.LastModified.Equal(mod) {
		t.Errorf("%+v", got)
	}
	s.SetTranscriptOffsets([]domain.TranscriptOffset{{URL: "/a/b.jsonl", ByteOffset: 99, LastModified: mod}})
	if s.TranscriptOffset("/a/b.jsonl").ByteOffset != 99 || len(s.AllTranscriptOffsets()) != 2 {
		t.Error("overwrite keeps the latest")
	}
	if s.TranscriptOffset("/nope") != nil {
		t.Error("unknown URL")
	}
}

func TestWritesLeaveOtherSectionsAndProviderBytesIntact(t *testing.T) {
	s, path := newStore(t)
	providers := `["claude",{"displayName":"Claude","id":"claude","status":{"unauthenticated":{}},"zzFuture":1.50}]`
	write(t, path, `{"schemaVersion":3,"providers":`+providers+`,"baselines":["grok",{"value":1,"date":"2026-03-14","lastValue":2,"lastUpdated":3}],"transcripts":{"/t":{"url":"/t","byteOffset":1,"lastModified":2}},"dailyUsage":[]}`)
	s.SetTranscriptOffsets([]domain.TranscriptOffset{{URL: "/x", ByteOffset: 5, LastModified: day1}})
	s.MaintainBaseline(domain.OpenRouter, day1, 1)
	s.AccumulateDailyUsage(domain.Claude, day1, 1, decimal.MustParse("0.5"), nil)

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"providers":`+providers) {
		t.Errorf("provider bytes changed: %s", data)
	}
	if s.Baseline("grok") == nil || s.TranscriptOffset("/t") == nil || s.TranscriptOffset("/x") == nil {
		t.Error("a write clobbered a section")
	}
	if len(s.LoadAll()) != 1 {
		t.Error("rows lost")
	}
	entries, _ := os.ReadDir(filepath.Dir(path))
	if len(entries) != 1 {
		t.Errorf("temp files left: %v", entries)
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0o644 {
		t.Errorf("mode %v", info.Mode().Perm())
	}
}

func TestNoopPassesDeltaThrough(t *testing.T) {
	got := Noop{}.AccumulateDailyUsage(domain.Claude, day1, 5, decimal.MustParse("1"), nil)
	if got.Tokens != 5 || got.CostUSD.String() != "1" {
		t.Errorf("%+v", got)
	}
}

func writeAllSections(s *File, now time.Time) {
	s.SetTranscriptOffsets([]domain.TranscriptOffset{
		{URL: "file:///z.jsonl", ByteOffset: 1, LastModified: day1.Add(123456789 * time.Nanosecond)},
		{URL: "file:///a.jsonl", ByteOffset: 7, LastModified: day1},
		{URL: "file:///m.jsonl", ByteOffset: 9, LastModified: day1.Add(time.Second / 3)},
	})
	for _, id := range []domain.ProviderID{domain.Codex, domain.OpenRouter, domain.Claude, domain.Gemini} {
		s.MaintainBaseline(id, now, 1.5)
		s.AccumulateDailyUsage(id, now, 0, decimal.FromInt(0), map[string]int{"zeta": 0, "alpha": 0, "mid": 0})
	}
}

// Swift encodes dictionaries unsorted, so a file from the app holds any key order. The first Go
// write settles the sections it owns; every later one with the same state is byte-identical.
func TestWritesOfIdenticalStateAreByteIdentical(t *testing.T) {
	seeds := map[string]string{
		"no file": "",
		"from the app": `{"dailyUsage":["gemini",{"tokens":3,"date":"2026-03-14","sessionTokens":{"z":1,"a":2},"costUSD":0.1}],` +
			`"transcripts":{"file:///z.jsonl":{"url":"file:///z.jsonl","lastModified":795182400.5,"byteOffset":1},"file:///b.jsonl":{"byteOffset":2,"url":"file:///b.jsonl","lastModified":795182401}},` +
			`"providers":["claude",` + state + `],"schemaVersion":3,` +
			`"baselines":["openrouter",{"lastValue":2,"value":1,"date":"2026-03-14","lastUpdated":795182400.25}]}`,
	}
	for name, seed := range seeds {
		t.Run(name, func(t *testing.T) {
			for run := 0; run < 20; run++ {
				s, path := newStore(t)
				if seed != "" {
					write(t, path, seed)
				}
				writeAllSections(s, day1)
				first, err := os.ReadFile(path)
				if err != nil {
					t.Fatal(err)
				}
				for again := 0; again < 3; again++ {
					writeAllSections(s, day1)
					next, _ := os.ReadFile(path)
					if string(next) != string(first) {
						t.Fatalf("write %d changed bytes:\n%s\n%s", again, first, next)
					}
				}
				other := NewFile(path, domain.NewDayKeyOwner(clock.Fixed(day1), time.UTC))
				writeAllSections(other, day1)
				if next, _ := os.ReadFile(path); string(next) != string(first) {
					t.Fatalf("a new process changed bytes:\n%s\n%s", first, next)
				}
			}
		})
	}
}

func TestWritesKeepTheAppsProviderRowsVerbatim(t *testing.T) {
	s, path := newStore(t)
	row := `{"status":{"unauthenticated":{}},"id":"claude","displayName":"Claude"}`
	write(t, path, `{"schemaVersion":3,"providers":["claude",`+row+`],"baselines":[],"transcripts":{},"dailyUsage":[]}`)
	writeAllSections(s, day1)
	data, _ := os.ReadFile(path)
	if !strings.Contains(string(data), row) {
		t.Fatalf("%s", data)
	}
}
