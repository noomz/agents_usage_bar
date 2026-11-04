package claude

import (
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/noomz/agents_usage_bar/cli/internal/jsonl"
)

func TestDecodeTranscript(t *testing.T) {
	cases := []struct {
		name  string
		line  string
		ok    bool
		total int
		reqID string
	}{
		{"basic", `{"type":"assistant","timestamp":"2026-05-13T10:00:00.000Z","requestId":"r","message":{"model":"m","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}`, true, 10, "r"},
		{"no fractional seconds", `{"type":"assistant","timestamp":"2026-05-13T10:00:00Z","message":{"usage":{"input_tokens":1}}}`, true, 1, ""},
		{"unknown fields", `{"type":"assistant","future":{"a":1},"timestamp":"2026-05-13T10:00:00Z","message":{"new":[1],"usage":{"input_tokens":5,"brand_new":9}}}`, true, 5, ""},
		{"wrong number types are zero", `{"type":"assistant","timestamp":"2026-05-13T10:00:00Z","message":{"usage":{"input_tokens":"7","output_tokens":1.5,"cache_read_input_tokens":2.0}}}`, true, 2, ""},
		{"user", `{"type":"user","timestamp":"2026-05-13T10:00:00Z","message":{"usage":{"input_tokens":1}}}`, false, 0, ""},
		{"permission mode", `{"type":"permission-mode","permissionMode":"default"}`, false, 0, ""},
		{"malformed", `{"type":"assistant", broken`, false, 0, ""},
		{"marker inside a string", `{"type":"user","text":"\"type\":\"assistant\"","timestamp":"2026-05-13T10:00:00Z"}`, false, 0, ""},
		{"no usage", `{"type":"assistant","timestamp":"2026-05-13T10:00:00Z","message":{}}`, false, 0, ""},
		{"bad timestamp", `{"type":"assistant","timestamp":"yesterday","message":{"usage":{}}}`, false, 0, ""},
		{"spaced type is skipped as in Swift", `{"type": "assistant","timestamp":"2026-05-13T10:00:00Z","message":{"usage":{"input_tokens":1}}}`, false, 0, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			record, ok := decodeTranscript([]byte(c.line))
			if ok != c.ok || (ok && record.totalTokens() != c.total) {
				t.Fatalf("ok %v total %d", ok, record.totalTokens())
			}
			if c.reqID != "" && (record.requestID == nil || *record.requestID != c.reqID) {
				t.Fatalf("request %v", record.requestID)
			}
		})
	}
}

func TestTranscriptFixtures(t *testing.T) {
	counts := map[string]int{
		"transcript-basic.jsonl": 2, "transcript-iso-no-fractional.jsonl": 1, "transcript-extra-fields.jsonl": 1,
		"transcript-malformed-line.jsonl": 2,
	}
	for name, want := range counts {
		read, err := jsonl.ReadDelta(fixtures+name, 0, nil)
		if err != nil {
			t.Fatal(err)
		}
		got := 0
		for _, line := range read.Lines {
			if _, ok := decodeTranscript(line); ok {
				got++
			}
		}
		if got != want {
			t.Errorf("%s: got %d records, want %d", name, got, want)
		}
	}
}

func TestSessionID(t *testing.T) {
	cases := map[string]string{
		"/r/p/s1.jsonl":                   "s1",
		"/r/p/s2/subagents/agent-a.jsonl": "s2",
	}
	for path, want := range cases {
		if got := sessionID(path); got != want {
			t.Errorf("%s: %s", path, got)
		}
	}
}

func TestPricing(t *testing.T) {
	table := decodePricing([]byte(fixture(t, "pricing-test-models.json")))
	str := func(s string) *string { return &s }
	cases := []struct {
		name  string
		model *string
		want  float64
	}{
		{"nil", nil, 2}, {"empty", str(""), 2},
		{"exact", str("test-model-exact"), 1},
		{"longer id with a known prefix", str("test-model-prefix-20260101"), 4},
		{"future opus", str("claude-opus-99"), 15},
		{"unknown", str("gpt-9"), 2},
	}
	for _, c := range cases {
		if got := table.rateFor(c.model).InputPer1M; got != c.want {
			t.Errorf("%s: %v", c.name, got)
		}
	}
	model := "test-model-exact"
	million := 1_000_000
	cost := table.cost(transcriptRecord{model: &model, inputTokens: million, outputTokens: million, cacheCreationTokens: million, cacheReadTokens: million})
	if f := cost.Float64(); math.Abs(f-7.35) > 1e-9 {
		t.Fatalf("cost %v", f)
	}
	if !table.cost(transcriptRecord{model: &model}).IsZero() {
		t.Fatal("zero tokens must cost zero")
	}
	unknown := "gpt-9"
	if f := table.cost(transcriptRecord{model: &unknown, inputTokens: million}).Float64(); f != 2 {
		t.Fatalf("default rate %v", f)
	}
}

func TestDefaultRoots(t *testing.T) {
	home := t.TempDir()
	if got := defaultRoots(home); len(got) != 0 {
		t.Fatalf("empty home: %v", got)
	}
	for _, dir := range []string{".claude/projects", ".ccs/shared/context-groups/default/projects", ".ccs/instances/work/projects", ".ccs/instances/.hidden/projects", ".ccs/instances/none"} {
		if err := os.MkdirAll(filepath.Join(home, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	joined := strings.Join(defaultRoots(home), "\n")
	for _, want := range []string{".claude/projects", "context-groups/default/projects", "instances/work/projects"} {
		if !strings.Contains(joined, want) {
			t.Errorf("missing %s in %s", want, joined)
		}
	}
	if strings.Contains(joined, ".hidden") || strings.Contains(joined, "none") {
		t.Errorf("%s", joined)
	}
}

func TestPricingDecodeFallback(t *testing.T) {
	if got := decodePricing([]byte(`nope`)); got.Default.InputPer1M != 3 {
		t.Fatalf("%+v", got)
	}
}
