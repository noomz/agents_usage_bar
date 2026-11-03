package pilocal

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/paths"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
)

const fixtures = "../../../../AgentsUsageBarTests/ProvidersPiLocalTests/Fixtures/"

var testNow = time.Date(2026, 4, 22, 12, 0, 0, 0, time.UTC)

func testEnv(home string, env map[string]string) provider.Env {
	return provider.Env{
		Cache: cache.Noop{}, Clock: clock.Fixed(testNow), DayKeys: domain.NewDayKeyOwner(clock.Fixed(testNow), time.UTC),
		Paths:  paths.For("linux", home, func(string) string { return "" }),
		Getenv: func(key string) string { return env[key] },
	}
}

func writeSession(t *testing.T, home, name, body string) string {
	t.Helper()
	path := filepath.Join(home, ".pi", "agent", "sessions", name)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func mixedFixture(t *testing.T, stamp string) string {
	t.Helper()
	raw, err := os.ReadFile(fixtures + "session-mixed.jsonl")
	if err != nil {
		t.Fatal(err)
	}
	return strings.ReplaceAll(string(raw), "<TS>", stamp)
}

func TestDecodeRecord(t *testing.T) {
	assistant := `{"type":"message","timestamp":"2026-04-22T12:00:00.000Z","message":{"role":"assistant","provider":"DRM-SWAP","model":"qwen3.8-27b","usage":{"input":33189,"output":293,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":33482,"cost":{"total":0}}}}`
	cases := []struct {
		name   string
		line   string
		ok     bool
		tokens int
		cost   string
	}{
		{"assistant prefers totalTokens", assistant, true, 33482, "0"},
		{"usage entry", `{"type":"usage","id":"u","parentId":null,"timestamp":"2026-04-22T12:00:00.000Z","kind":"cache_warm","provider":"DRM-SWAP","model":"qwen3.8-27b","usage":{"input":100,"output":0,"totalTokens":100,"cost":{"total":0.5}}}`, true, 100, "0.5"},
		{"sums parts when no total", `{"type":"message","timestamp":"2026-04-22T12:00:00Z","message":{"role":"assistant","provider":"ollama","model":"m","usage":{"input":10,"output":5,"cacheRead":1,"cacheWrite":2,"reasoning":3}}}`, true, 21, "0"},
		{"spaced type", `{"type": "usage", "timestamp":"2026-04-22T12:00:00Z","provider":"p","usage":{"totalTokens":1}}`, true, 1, "0"},
		{"user message", `{"type":"message","timestamp":"2026-04-22T12:00:00Z","message":{"role":"user","provider":"DRM-SWAP"}}`, false, 0, ""},
		{"compaction", `{"type":"compaction","timestamp":"2026-04-22T12:00:00Z","usage":{"totalTokens":9}}`, false, 0, ""},
		{"branch summary", `{"type":"branch_summary","timestamp":"2026-04-22T12:00:00Z","usage":{"totalTokens":9}}`, false, 0, ""},
		{"malformed", `not-json`, false, 0, ""},
		{"session", `{"type":"session","timestamp":"2026-04-22T12:00:00Z"}`, false, 0, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			record, ok := DecodeRecord([]byte(c.line))
			if ok != c.ok {
				t.Fatalf("ok = %v", ok)
			}
			if ok && (record.Tokens != c.tokens || record.CostUSD.String() != c.cost) {
				t.Fatalf("tokens %d cost %s", record.Tokens, record.CostUSD)
			}
		})
	}
}

func TestNumberDecimalMatchesFoundation(t *testing.T) {
	cases := [][2]string{
		{"0.00123456789012345678", "0.00123456789012345678"},
		{"0.5", "0.5"}, {"0", "0"}, {"5", "5"}, {"1e-7", "0.0000001"},
		{"0.0314159265358979", "0.0314159265358979"},
		{"0.30000000000000004", "0.3"},
		{"0.000042000000000000004", "0.000042000000000000004"},
		{"0.0000702216", "0.00007022160000000001"},
		{"0.00055257", "0.0005525699999999999"},
		{"0.00017476040000000001", "0.00017476040000000001"},
		{"0.00071063782044275", "0.0007106378204427501"},
	}
	for _, c := range cases {
		if got := numberDecimal(c[0]).String(); got != c[1] {
			t.Errorf("%s: got %s, want %s", c[0], got, c[1])
		}
	}
}

func TestIsLocal(t *testing.T) {
	cases := []struct {
		id, base string
		want     bool
	}{
		{"llama.cpp", "", true},
		{"llama.cpp", "https://example.com/v1", true},
		{"ollama", "http://localhost:11434/v1", true},
		{"lan", "http://10.1.2.3:8080/v1", true},
		{"lan", "http://172.16.0.2:8080/v1", true},
		{"lan", "http://192.168.1.9:8080/v1", true},
		{"lan", "http://169.254.1.1:8080/v1", true},
		{"lan", "http://nas.local:8080/v1", true},
		{"DRM-SWAP", "http://drm:8080/v1", true},
		{"v6", "http://[::1]:8080/v1", true},
		{"v6ll", "http://[fe80::1]/v1", true},
		{"remote", "https://api.example.com/v1", false},
		{"remote", "http://api.example.com/v1", false},
		{"missing", "", false},
	}
	for _, id := range []string{"anthropic", "openai", "openai-codex", "openrouter", "xai", "amazon-bedrock", "router", "google", "gemini"} {
		cases = append(cases, struct {
			id, base string
			want     bool
		}{id, "http://127.0.0.1:4000", false})
	}
	for _, c := range cases {
		if got := IsLocal(c.id, c.base); got != c.want {
			t.Errorf("%s %s: got %v", c.id, c.base, got)
		}
	}
}

func TestLoadCatalog(t *testing.T) {
	catalog := LoadCatalog([]string{fixtures + "models-local.json"})
	for id, want := range map[string]bool{"DRM-SWAP": true, "ollama": true, "llama.cpp": true, "openrouter": false, "anthropic": false} {
		if catalog[id] != want {
			t.Errorf("%s: got %v", id, catalog[id])
		}
	}
	if missing := LoadCatalog([]string{"/nonexistent/models.json"}); len(missing) != 1 || !missing["llama.cpp"] {
		t.Errorf("missing file: %v", missing)
	}
}

func TestSessionDirs(t *testing.T) {
	root := t.TempDir()
	sessions := filepath.Join(root, ".pi", "agent", "sessions")
	if err := os.MkdirAll(sessions, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "pi-agent-link")
	if err := os.Symlink(filepath.Join(root, ".pi", "agent"), link); err != nil {
		t.Fatal(err)
	}
	if dirs := SessionDirs(func(string) string { return link }, root); len(dirs) != 1 {
		t.Fatalf("symlinked override did not collapse: %v", dirs)
	}
	other := t.TempDir()
	if dirs := SessionDirs(func(string) string { return other }, root); len(dirs) != 2 {
		t.Fatalf("distinct override: %v", dirs)
	}
	if got := AgentDir(func(string) string { return "" }, "/h"); got != filepath.Join("/h", ".pi", "agent") {
		t.Fatal(got)
	}
}

func TestFetch(t *testing.T) {
	home := t.TempDir()
	writeSession(t, home, "s.jsonl", mixedFixture(t, "2026-04-22T11:00:00.000Z")+
		`{"type":"usage","timestamp":"2026-04-22T11:00:00Z","kind":"cache_warm","provider":"DRM-SWAP","model":"qwen3.8-27b","usage":{"totalTokens":100,"cost":{"total":0}}}`+"\n"+
		`{"type":"message","timestamp":"2026-04-21T23:59:59Z","message":{"role":"assistant","provider":"DRM-SWAP","model":"old","usage":{"totalTokens":7}}}`+"\n")
	models := filepath.Join(home, ".pi", "agent", "models.json")
	raw, err := os.ReadFile(fixtures + "models-local.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(models, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	p := Build(testEnv(home, nil))
	snap, status, err := p.Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if *snap.TokensToday != 33582 || snap.Raw["providers"] != "DRM-SWAP" || snap.Raw["models"] != "qwen3.8-27b" || snap.Raw["filesRead"] != "1" {
		t.Fatalf("%v %v", *snap.TokensToday, snap.Raw)
	}
	if snap.Quota != nil || status.Kind != domain.StatusOK || snap.ProviderID != domain.PiLocal {
		t.Fatalf("%+v", status)
	}
	caps := p.Capabilities()
	if !caps.HasTokens || !caps.HasCost || caps.HasQuota || caps.IsLocal {
		t.Fatalf("%+v", caps)
	}
}

func TestFetchNoRootIsUnauthenticated(t *testing.T) {
	p := Build(testEnv(t.TempDir(), nil))
	snap, status, err := p.Fetch(context.Background(), testNow)
	if err != nil {
		t.Fatal(err)
	}
	if snap.Raw[domain.RawProviderStatus] != domain.StatusSentinelUnauth || status.Kind != domain.StatusUnauthenticated || *snap.TokensToday != 0 {
		t.Fatalf("%+v %+v", snap, status)
	}
}

type recordingStore struct {
	cache.Noop
	offsets map[string]domain.TranscriptOffset
}

func (s *recordingStore) WithCursors(body func(cache.Cursors))                     { body(s) }
func (s *recordingStore) AllTranscriptOffsets() map[string]domain.TranscriptOffset { return s.offsets }
func (s *recordingStore) SetTranscriptOffsets(o []domain.TranscriptOffset) {
	for _, offset := range o {
		s.offsets[offset.URL] = offset
	}
}

func TestReadSessionsResumesAtCursorAndPrefixesKeys(t *testing.T) {
	home := t.TempDir()
	line := `{"type":"usage","timestamp":"2026-04-22T11:00:00Z","provider":"p","usage":{"totalTokens":10,"cost":{"total":0.25}}}` + "\n"
	path := writeSession(t, home, "a.jsonl", line)
	roots := SessionDirs(func(string) string { return "" }, home)
	store := &recordingStore{offsets: map[string]domain.TranscriptOffset{}}
	today := testNow.Add(-12 * time.Hour)

	first, err := ReadSessions(store, roots, Catalog{"p": true}, today, "grok:")
	if err != nil || first.Acc.Tokens != 10 || first.Acc.CostUSD.Cmp(decimal.MustParse("0.25")) != 0 {
		t.Fatalf("%v %+v", err, first)
	}
	for key := range store.offsets {
		if !strings.HasPrefix(key, "grok:file://") {
			t.Fatalf("key %s", key)
		}
	}
	if second, _ := ReadSessions(store, roots, Catalog{"p": true}, today, "grok:"); second.Acc.Tokens != 0 {
		t.Fatalf("second read recounted: %+v", second)
	}
	if other, _ := ReadSessions(store, roots, Catalog{"p": true}, today, ""); other.Acc.Tokens != 10 {
		t.Fatalf("a reader under another prefix must count the file itself: %+v", other)
	}
	if err := os.WriteFile(path, []byte(line+line), 0o644); err != nil {
		t.Fatal(err)
	}
	if third, _ := ReadSessions(store, roots, Catalog{"p": true}, today, "grok:"); third.Acc.Tokens != 10 {
		t.Fatalf("appended line: %+v", third)
	}
}
