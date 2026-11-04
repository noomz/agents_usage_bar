package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/paths"
)

const (
	transcriptLines = 20000
	tokensPerLine   = 3
	wantTokens      = transcriptLines * tokensPerLine
	concurrentRuns  = 6
	rounds          = 25
)

func buildAub(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "aub")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	return bin
}

func seedHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	path := filepath.Join(home, ".claude", "projects", "p", "s.jsonl")
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	line := fmt.Sprintf(`{"type":"assistant","timestamp":%q,"message":{"model":"claude-test","role":"assistant","usage":{"input_tokens":%d,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}`+"\n",
		time.Now().UTC().Format(time.RFC3339), tokensPerLine)
	if err := os.WriteFile(path, []byte(strings.Repeat(line, transcriptLines)), 0o600); err != nil {
		t.Fatal(err)
	}
	return home
}

func runAub(t *testing.T, bin, home string) {
	t.Helper()
	cmd := exec.Command(bin, "usage", "claude", "--live", "--json")
	cmd.Env = []string{"HOME=" + home, "PATH=/usr/bin:/bin"}
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Errorf("aub: %v: %s", err, out)
	}
}

// storedTokens reads the store rather than stdout: a Mac whose app preference selects hook mode
// prints no token row for a home with no hook feed, yet still accumulates.
func storedTokens(t *testing.T, home string) int {
	t.Helper()
	path := paths.For(runtime.GOOS, home, func(string) string { return "" }).CacheFile()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var store struct {
		DailyUsage []json.RawMessage `json:"dailyUsage"`
	}
	if err := json.Unmarshal(data, &store); err != nil || len(store.DailyUsage) != 2 {
		t.Fatalf("%v: %s", err, data)
	}
	var record struct {
		Tokens int `json:"tokens"`
	}
	if err := json.Unmarshal(store.DailyUsage[1], &record); err != nil {
		t.Fatal(err)
	}
	return record.Tokens
}

// Real processes share one store with no credential, so no network is involved. Each round has
// its own home, so one lost cursor write cannot hide behind a later round.
func TestConcurrentRunsNeverDoubleToday(t *testing.T) {
	bin := buildAub(t)
	for round := range rounds {
		home := seedHome(t)
		stagger := time.Duration(round%5) * 3 * time.Millisecond
		var wg sync.WaitGroup
		for i := range concurrentRuns {
			wg.Add(1)
			go func() {
				defer wg.Done()
				time.Sleep(time.Duration(i) * stagger)
				runAub(t, bin, home)
			}()
		}
		wg.Wait()
		if got := storedTokens(t, home); got != wantTokens {
			t.Errorf("round %d: stored %d, want %d", round, got, wantTokens)
		}
		runAub(t, bin, home)
		if got := storedTokens(t, home); got != wantTokens {
			t.Errorf("round %d: stored %d after one more run, want %d", round, got, wantTokens)
		}
	}
}
