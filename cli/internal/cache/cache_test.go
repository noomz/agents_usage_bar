package cache

import (
	"errors"
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

func cursorsOf(s *File) Cursors { return fileCursors{s} }

func baselineOf(t *testing.T, s *File, id domain.ProviderID) *domain.BaselineRecord {
	t.Helper()
	b, available := s.Baseline(id)
	if !available {
		t.Fatal("baseline unavailable")
	}
	return b
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
	if len(s.LoadAll()) != 0 || len(cursorsOf(s).AllTranscriptOffsets()) != 0 || baselineOf(t, s, domain.Claude) != nil {
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
	b := baselineOf(t, s, domain.OpenRouter)
	if b.Value != 10 || b.LastValue != 10 || b.Date != "2026-03-14" {
		t.Errorf("cold start: %+v", b)
	}
	s.MaintainBaseline(domain.OpenRouter, day1, 15)
	if b = baselineOf(t, s, domain.OpenRouter); b.Value != 10 || b.LastValue != 15 {
		t.Errorf("same day: %+v", b)
	}
	s.MaintainBaseline(domain.OpenRouter, day1, 7)
	if b = baselineOf(t, s, domain.OpenRouter); b.Value != 7 || b.LastValue != 7 {
		t.Errorf("negative delta: %+v", b)
	}
	s.MaintainBaseline(domain.OpenRouter, day2, 20)
	if b = baselineOf(t, s, domain.OpenRouter); b.Value != 20 || b.Date != "2026-03-15" {
		t.Errorf("next day: %+v", b)
	}
}

func TestAccumulateDailyUsage(t *testing.T) {
	s, path := newStore(t)
	one := decimal.MustParse("0.1")
	got := cursorsOf(s).AccumulateDailyUsage(domain.Claude, day1, 5, one, map[string]int{"a": 2})
	if got.Tokens != 5 || got.CostUSD.String() != "0.1" {
		t.Errorf("%+v", got)
	}
	got = cursorsOf(s).AccumulateDailyUsage(domain.Claude, day1, 3, decimal.MustParse("0.2"), map[string]int{"a": 1, "b": 4})
	if got.Tokens != 8 || got.CostUSD.String() != "0.3" || got.SessionTokens["a"] != 3 || got.SessionTokens["b"] != 4 {
		t.Errorf("sum: %+v", got)
	}
	other := cursorsOf(s).AccumulateDailyUsage(domain.Codex, day1, 1, one, nil)
	if other.Tokens != 1 {
		t.Errorf("providers are isolated: %+v", other)
	}
	fresh := NewFile(path, domain.NewDayKeyOwner(clock.Fixed(day1), time.UTC))
	got = cursorsOf(fresh).AccumulateDailyUsage(domain.Claude, day1, 1, one, nil)
	if got.Tokens != 9 || got.CostUSD.String() != "0.4" {
		t.Errorf("persisted: %+v", got)
	}
	got = cursorsOf(fresh).AccumulateDailyUsage(domain.Claude, day2, 2, one, map[string]int{"c": 1})
	if got.Tokens != 2 || got.CostUSD.String() != "0.1" || got.SessionTokens["a"] != 0 {
		t.Errorf("rollover: %+v", got)
	}
}

func TestOldCacheWithoutSessionTokensReadsEmpty(t *testing.T) {
	s, path := newStore(t)
	write(t, path, `{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":["claude",{"date":"2026-03-14","tokens":5,"costUSD":1.5}]}`)
	got := cursorsOf(s).AccumulateDailyUsage(domain.Claude, day1, 1, decimal.MustParse("0.5"), nil)
	if got.Tokens != 6 || got.CostUSD.String() != "2" {
		t.Errorf("%+v", got)
	}
}

func TestTranscriptOffsets(t *testing.T) {
	s, _ := newStore(t)
	mod := time.Date(2026, 3, 14, 1, 2, 3, 500_000_000, time.UTC)
	cursorsOf(s).SetTranscriptOffsets([]domain.TranscriptOffset{{URL: "/a/b.jsonl", ByteOffset: 10, LastModified: mod}, {URL: "/c.jsonl", ByteOffset: 20, LastModified: mod}})
	got := cursorsOf(s).AllTranscriptOffsets()["/a/b.jsonl"]
	if got.ByteOffset != 10 || !got.LastModified.Equal(mod) {
		t.Errorf("%+v", got)
	}
	cursorsOf(s).SetTranscriptOffsets([]domain.TranscriptOffset{{URL: "/a/b.jsonl", ByteOffset: 99, LastModified: mod}})
	if cursorsOf(s).AllTranscriptOffsets()["/a/b.jsonl"].ByteOffset != 99 || len(cursorsOf(s).AllTranscriptOffsets()) != 2 {
		t.Error("overwrite keeps the latest")
	}
	if _, ok := cursorsOf(s).AllTranscriptOffsets()["/nope"]; ok {
		t.Error("unknown URL")
	}
}

func TestWritesLeaveOtherSectionsAndProviderBytesIntact(t *testing.T) {
	s, path := newStore(t)
	providers := `["claude",{"displayName":"Claude","id":"claude","status":{"unauthenticated":{}},"zzFuture":1.50}]`
	write(t, path, `{"schemaVersion":3,"providers":`+providers+`,"baselines":["grok",{"value":1,"date":"2026-03-14","lastValue":2,"lastUpdated":3}],"transcripts":{"/t":{"url":"/t","byteOffset":1,"lastModified":2}},"dailyUsage":[]}`)
	cursorsOf(s).SetTranscriptOffsets([]domain.TranscriptOffset{{URL: "/x", ByteOffset: 5, LastModified: day1}})
	s.MaintainBaseline(domain.OpenRouter, day1, 1)
	cursorsOf(s).AccumulateDailyUsage(domain.Claude, day1, 1, decimal.MustParse("0.5"), nil)

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"providers":`+providers) {
		t.Errorf("provider bytes changed: %s", data)
	}
	if baselineOf(t, s, "grok") == nil || len(cursorsOf(s).AllTranscriptOffsets()) != 2 {
		t.Error("a write clobbered a section")
	}
	if len(s.LoadAll()) != 1 {
		t.Error("rows lost")
	}
	leftovers, _ := filepath.Glob(filepath.Join(filepath.Dir(path), ".today-*"))
	if len(leftovers) != 0 {
		t.Errorf("temp files left: %v", leftovers)
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
	cursorsOf(s).SetTranscriptOffsets([]domain.TranscriptOffset{
		{URL: "file:///z.jsonl", ByteOffset: 1, LastModified: day1.Add(123456789 * time.Nanosecond)},
		{URL: "file:///a.jsonl", ByteOffset: 7, LastModified: day1},
		{URL: "file:///m.jsonl", ByteOffset: 9, LastModified: day1.Add(time.Second / 3)},
	})
	for _, id := range []domain.ProviderID{domain.Codex, domain.OpenRouter, domain.Claude, domain.Gemini} {
		s.MaintainBaseline(id, now, 1.5)
		cursorsOf(s).AccumulateDailyUsage(id, now, 0, decimal.FromInt(0), map[string]int{"zeta": 0, "alpha": 0, "mid": 0})
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

func exerciseEveryWriter(t *testing.T, s *File) {
	t.Helper()
	if err := s.MaintainBaseline(domain.OpenRouter, day1, 10); err != nil && !errors.Is(err, errUnusable) {
		t.Fatal(err)
	}
	err := s.WithCursors(func(c Cursors) {
		c.SetTranscriptOffsets([]domain.TranscriptOffset{{URL: "/a", ByteOffset: 1, LastModified: day1}})
		c.AccumulateDailyUsage(domain.Claude, day1, 7, decimal.MustParse("0.5"), map[string]int{"s": 7})
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestNewerSchemaIsNeverWrittenOrMoved(t *testing.T) {
	body := `{"schemaVersion":4,"providers":[],"baselines":["openrouter",{"value":1}],"transcripts":{},"dailyUsage":[],"futureSection":{"a":1}}`
	s, path := newStore(t)
	write(t, path, body)
	stamp := time.Date(2020, 1, 2, 3, 4, 5, 0, time.UTC)
	if err := os.Chtimes(path, stamp, stamp); err != nil {
		t.Fatal(err)
	}
	if _, available := s.Baseline(domain.OpenRouter); available {
		t.Error("baseline from a newer schema")
	}
	if err := s.MaintainBaseline(domain.OpenRouter, day1, 10); !errors.Is(err, errUnusable) {
		t.Errorf("MaintainBaseline: %v", err)
	}
	err := s.WithCursors(func(c Cursors) {
		if len(c.AllTranscriptOffsets()) != 0 {
			t.Error("cursors from a newer schema")
		}
		c.SetTranscriptOffsets([]domain.TranscriptOffset{{URL: "/a", ByteOffset: 1, LastModified: day1}})
		if got := c.AccumulateDailyUsage(domain.Claude, day1, 7, decimal.MustParse("0.5"), map[string]int{"s": 7}); got.Tokens != 7 || got.SessionTokens["s"] != 7 {
			t.Errorf("delta must pass through: %+v", got)
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != body || !info.ModTime().Equal(stamp) {
		t.Fatalf("file changed: %s", data)
	}
	if _, err := os.Stat(path + ".corrupt"); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("a newer schema was moved aside")
	}
}

var corruptBodies = map[string]string{
	"truncated":              `{"schemaVersion":3,"providers":[],"base`,
	"empty":                  ``,
	"no schema":              `{"providers":[]}`,
	"schema zero":            `{"schemaVersion":0,"providers":[],"baselines":[]}`,
	"v3 missing a section":   `{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{}}`,
	"one bad cursor":         `{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{"/good":{"url":"/good","byteOffset":500,"lastModified":1},"/bad":{"url":"/bad","byteOffset":-1,"lastModified":1}},"dailyUsage":["claude",{"date":"2026-03-14","tokens":5000,"costUSD":1}]}`,
	"future-shape cursors":   `{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{"/a":{"path":"/a","position":500}},"dailyUsage":["claude",{"date":"2026-03-14","tokens":5000,"costUSD":1}]}`,
	"transcripts wrong type": `{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":[],"dailyUsage":["claude",{"date":"2026-03-14","tokens":5000,"costUSD":1}]}`,
	"baselines wrong type":   `{"schemaVersion":3,"providers":[],"baselines":{},"transcripts":{},"dailyUsage":[]}`,
	"bad baseline":           `{"schemaVersion":3,"providers":[],"baselines":["openrouter",{"value":1}],"transcripts":{},"dailyUsage":[]}`,
	"daily wrong type":       `{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":{}}`,
	"bad daily record":       `{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":["claude",{"tokens":"x"}]}`,
	"providers wrong type":   `{"schemaVersion":3,"providers":{},"baselines":[],"transcripts":{},"dailyUsage":[]}`,
}

func TestCorruptFileMovesAsideAndCountingRestartsOnce(t *testing.T) {
	for name, body := range corruptBodies {
		t.Run(name, func(t *testing.T) {
			s, path := newStore(t)
			write(t, path, body)
			if _, available := s.Baseline(domain.OpenRouter); available {
				t.Error("baseline from a corrupt file")
			}
			if len(s.LoadAll()) != 0 {
				t.Error("rows from a corrupt file")
			}
			if data, _ := os.ReadFile(path); string(data) != body {
				t.Fatal("a read changed the file")
			}

			var first domain.DailyUsageRecord
			err := s.WithCursors(func(c Cursors) {
				if len(c.AllTranscriptOffsets()) != 0 {
					t.Error("cursors survived")
				}
				c.SetTranscriptOffsets([]domain.TranscriptOffset{{URL: "/a", ByteOffset: 100, LastModified: day1}})
				first = c.AccumulateDailyUsage(domain.Claude, day1, 100, decimal.MustParse("1"), nil)
			})
			if err != nil {
				t.Fatal(err)
			}
			if first.Tokens != 100 {
				t.Errorf("first run total %d, want the delta alone", first.Tokens)
			}
			if aside, err := os.ReadFile(path + ".corrupt"); err != nil || string(aside) != body {
				t.Fatalf("original bytes lost: %v %q", err, aside)
			}
			err = s.WithCursors(func(c Cursors) {
				if c.AllTranscriptOffsets()["/a"].ByteOffset != 100 {
					t.Error("cursor did not persist")
				}
				if got := c.AccumulateDailyUsage(domain.Claude, day1, 5, decimal.MustParse("1"), nil); got.Tokens != 105 {
					t.Errorf("later run total %d, want 105", got.Tokens)
				}
			})
			if err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestCorruptCopyKeepsOnlyTheLatest(t *testing.T) {
	s, path := newStore(t)
	write(t, path+".corrupt", "older damage")
	write(t, path, `{"newer":"damage`)
	exerciseEveryWriter(t, s)
	if aside, _ := os.ReadFile(path + ".corrupt"); string(aside) != `{"newer":"damage` {
		t.Fatalf("%q", aside)
	}
	matches, _ := filepath.Glob(path + "*")
	if len(matches) != 3 {
		t.Fatalf("want store, lock, and one copy: %v", matches)
	}
}

func TestCorruptFileInReadOnlyDirectoryPassesDeltaThrough(t *testing.T) {
	skipIfRoot(t)
	s, path := newStore(t)
	write(t, path, "{broken")
	write(t, path+".lock", "")
	if err := os.Chmod(filepath.Dir(path), 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(filepath.Dir(path), 0o755) })
	exerciseEveryWriter(t, s)
	err := s.WithCursors(func(c Cursors) {
		if got := c.AccumulateDailyUsage(domain.Claude, day1, 7, decimal.MustParse("0.5"), nil); got.Tokens != 7 {
			t.Errorf("total %d, want the delta", got.Tokens)
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(path); string(data) != "{broken" {
		t.Fatalf("%q", data)
	}
}

func TestBadProviderRowIsNotCorruption(t *testing.T) {
	body := `{"schemaVersion":3,"providers":["x",{"id":"x"}],"baselines":[],"transcripts":{"/a":{"url":"/a","byteOffset":5,"lastModified":1}},"dailyUsage":[]}`
	s, path := newStore(t)
	write(t, path, body)
	if err := s.WithCursors(func(c Cursors) {
		if c.AllTranscriptOffsets()["/a"].ByteOffset != 5 {
			t.Error("cursor lost")
		}
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path + ".corrupt"); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("moved aside")
	}
}

const (
	oneBaseline = `["openrouter",{"value":1,"date":"2026-03-14","lastValue":1,"lastUpdated":1}]`
)

// Each body is one Swift's decoder may accept, so Go keeps the bytes where they are.
var foreignOrIgnoredBodies = map[string]struct {
	body    string
	foreign bool
}{
	"v4 point zero":       {`{"schemaVersion":4.0,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":[]}`, true},
	"huge version":        {`{"schemaVersion":1000000000000000000000000000000,"providers":[],"baselines":[]}`, true},
	"exponent version":    {`{"schemaVersion":4e0,"providers":[],"baselines":[]}`, true},
	"utf8 bom":            {"\xef\xbb\xbf" + `{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":[]}`, true},
	"utf16 bom":           {"\xff\xfe{\x00\"\x00", true},
	"utf16 no bom":        {"{\x00\"\x00s\x00", true},
	"not an object":       {`[]`, true},
	"offset beyond int64": {`{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{"/a":{"url":"/a","byteOffset":99999999999999999999,"lastModified":1}},"dailyUsage":[]}`, true},
	"tokens beyond int64": {`{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":["claude",{"date":"2026-03-14","tokens":1e30,"costUSD":1}]}`, true},
	"session tokens huge": {`{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":["claude",{"date":"2026-03-14","tokens":1,"costUSD":1,"sessionTokens":{"s":1e30}}]}`, true},
}

func TestForeignLookingStoresAreNeverMovedOrWritten(t *testing.T) {
	for name, c := range foreignOrIgnoredBodies {
		t.Run(name, func(t *testing.T) {
			s, path := newStore(t)
			write(t, path, c.body)
			if err := s.MaintainBaseline(domain.OpenRouter, day1, 10); !errors.Is(err, errUnusable) {
				t.Errorf("MaintainBaseline: %v", err)
			}
			err := s.WithCursors(func(c Cursors) {
				c.SetTranscriptOffsets([]domain.TranscriptOffset{{URL: "/a", ByteOffset: 1, LastModified: day1}})
				c.AccumulateDailyUsage(domain.Claude, day1, 7, decimal.MustParse("0.5"), nil)
			})
			if err != nil {
				t.Fatal(err)
			}
			if data, _ := os.ReadFile(path); string(data) != c.body {
				t.Fatalf("file changed: %q", data)
			}
			if _, err := os.Stat(path + ".corrupt"); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("moved aside")
			}
		})
	}
}

func TestOlderSchemaIgnoresSectionsItNeverHad(t *testing.T) {
	bad := map[string]string{
		"v1 bad transcripts":  `{"schemaVersion":1,"providers":[],"baselines":[],"transcripts":"x"}`,
		"v1 null transcripts": `{"schemaVersion":1.0,"providers":[],"baselines":[],"transcripts":null}`,
		"v1 bad daily":        `{"schemaVersion":1,"providers":[],"baselines":[],"dailyUsage":{"a":1}}`,
		"v2 bad daily":        `{"schemaVersion":2,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":["odd"]}`,
		"v2 daily string":     `{"schemaVersion":2,"providers":[],"baselines":[],"transcripts":{},"dailyUsage":"x"}`,
		"v3 point zero":       `{"schemaVersion":3.0,"providers":[],"baselines":[` + oneBaseline[1:len(oneBaseline)-1] + `],"transcripts":{},"dailyUsage":[]}`,
		"v3 exponent offset":  `{"schemaVersion":3,"providers":[],"baselines":[],"transcripts":{"/a":{"url":"/a","byteOffset":1e16,"lastModified":1}},"dailyUsage":[]}`,
	}
	for name, body := range bad {
		t.Run(name, func(t *testing.T) {
			s, path := newStore(t)
			write(t, path, body)
			if err := s.MaintainBaseline(domain.OpenRouter, day1, 10); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(path + ".corrupt"); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("a usable store was moved aside")
			}
			data, _ := os.ReadFile(path)
			if strings.Contains(string(data), `"x"`) || strings.Contains(string(data), `"odd"`) {
				t.Fatalf("ignored section was carried forward: %s", data)
			}
		})
	}
}
