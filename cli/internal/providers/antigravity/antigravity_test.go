package antigravity

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/paths"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
)

func TestFetchGroupedQuota(t *testing.T) {
	p := fakeCLI(t, `[ "$PWD" = / ] && [ "$*" = '--print /usage --output-format json --print-timeout 8s' ] || exit 1
exec /bin/cat "$HOME/usage.json"`)
	data, err := os.ReadFile("../../../../AgentsUsageBarTests/ProvidersAntigravityTests/Fixtures/usage.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(p.home, "usage.json"), data, 0600); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	snap, status, err := p.Fetch(context.Background(), now)
	if err != nil || status.Kind != domain.OK(now).Kind {
		t.Fatalf("fetch status=%+v, err=%v", status, err)
	}
	var names []string
	var used, durations []float64
	for _, w := range snap.QuotaWindows {
		names = append(names, w.Name)
		if w.Utilization == nil || w.Duration == nil {
			t.Fatalf("incomplete window: %+v", w)
		}
		used = append(used, *w.Utilization)
		durations = append(durations, *w.Duration)
	}
	if !reflect.DeepEqual(names, []string{"Gemini Models 7d", "Gemini Models 5h", "Claude and GPT models 7d", "Claude and GPT models 5h"}) ||
		!reflect.DeepEqual(used, []float64{0.25, 0, 1, 0.5}) || !reflect.DeepEqual(durations, []float64{604800, 18000, 604800, 18000}) {
		t.Fatalf("quota windows: %v, used: %v, durations: %v", names, used, durations)
	}
	wantReset := time.Date(2026, 11, 20, 14, 0, 19, 123000000, time.UTC)
	if reset := snap.QuotaWindows[3].ResetsAt; reset == nil || !reset.Equal(wantReset) {
		t.Fatalf("reset = %v, want %v", reset, wantReset)
	}
	if snap.TokensToday != nil || snap.CostTodayUSD != nil || snap.Quota == nil || snap.Quota.Used != 1 {
		t.Fatalf("wrong totals or aggregate quota: %+v", snap)
	}
}

func TestFetchDoesNotLaunchWithoutLogin(t *testing.T) {
	p := fakeCLI(t, "exit 1")
	if err := os.Remove(filepath.Join(p.home, ".gemini", "antigravity-cli", "antigravity-oauth-token")); err != nil {
		t.Fatal(err)
	}
	snap, status, err := p.Fetch(context.Background(), time.Now())
	if err != nil || status.Kind != domain.Unauthenticated().Kind || snap.Quota != nil {
		t.Fatalf("signed out: snapshot=%+v, status=%+v, err=%v", snap, status, err)
	}
}

func TestFetchErrors(t *testing.T) {
	for _, tc := range []struct {
		name, script string
		want         domain.ProviderErrorKind
	}{
		{"missing quota", `printf '%s' '{"status":"SUCCESS","response":"No usage available"}'`, domain.ErrDecode},
		{"command failure", "exit 1", domain.ErrUnknown},
		{"hang", "exec /bin/sleep 60", domain.ErrNetwork},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := fakeCLI(t, tc.script)
			if tc.name == "hang" {
				p.timeout = 200 * time.Millisecond
			}
			_, _, err := p.Fetch(context.Background(), time.Now())
			var failure domain.ProviderError
			if !errors.As(err, &failure) || failure.Kind != tc.want {
				t.Fatalf("error = %v, want %v", err, tc.want)
			}
		})
	}
}

func fakeCLI(t *testing.T, script string) *Provider {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("requires /bin/sh")
	}
	home := t.TempDir()
	if err := os.WriteFile(filepath.Join(home, "agy"), []byte("#!/bin/sh\n"+script+"\n"), 0700); err != nil {
		t.Fatal(err)
	}
	root := filepath.Join(home, ".gemini", "antigravity-cli")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "antigravity-oauth-token"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	p := Build(provider.Env{Paths: paths.Layout{Home: home}, Getenv: func(string) string { return home }})
	if p == nil {
		t.Fatal("didn't discover agy on PATH")
	}
	return p.(*Provider)
}
