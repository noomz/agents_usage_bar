package codex

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

func tokenLine(ts string, total int, limits string) string {
	if limits != "" {
		limits = `,"rate_limits":` + limits
	}
	return fmt.Sprintf(`{"timestamp":%q,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":%d,"cached_input_tokens":0,"output_tokens":0,"total_tokens":%d}}%s}}`, ts, total, total, limits)
}

func utcDay(t time.Time) string { return t.UTC().Format("2006-01-02") }

func TestLastTokenCount(t *testing.T) {
	const windows = `{"limit_id":"codex","primary":{"used_percent":98.0,"window_minutes":300,"resets_at":1788858959},"secondary":{"used_percent":15.0,"window_minutes":10080,"resets_at":1789445759},"plan_type":"plus"}`
	secondaryPct := func(p float64) *float64 { return &p }
	cases := []struct {
		name      string
		files     []string
		found     bool
		total     int
		primary   *float64
		secondary *float64
		limitID   string
	}{
		{name: "no files"},
		{name: "only session meta", files: []string{`{"timestamp":"2026-04-24T11:00:00.000Z","type":"session_meta","payload":{"cwd":"/x"}}`}},
		{
			name: "nil info is skipped",
			files: []string{`{"timestamp":"2026-04-24T11:00:00.000Z","type":"event_msg","payload":{"type":"token_count"}}
` + tokenLine("2026-04-24T11:01:00.000Z", 2, "")},
			found: true, total: 2,
		},
		{
			name:  "truncated last line is skipped",
			files: []string{tokenLine("2026-04-24T11:01:00.000Z", 7, "") + "\n" + `{"timestamp":"2026-04-24T11:57:00.000Z","type":"event_msg","payload":{"type":"token_count"`},
			found: true, total: 7,
		},
		{
			name:  "last line without a newline still counts",
			files: []string{tokenLine("2026-04-24T11:01:00.000Z", 7, "") + "\n" + tokenLine("2026-04-24T11:02:00.000Z", 8, "")},
			found: true, total: 8,
		},
		{
			name:  "latest timestamp wins across files either way round",
			files: []string{tokenLine("2026-04-24T12:00:00.000Z", 9, ""), tokenLine("2026-04-24T11:00:00.000Z", 100, "")},
			found: true, total: 9,
		},
		{
			name:  "timestamp without fraction parses",
			files: []string{tokenLine("2026-04-24T12:00:00Z", 9, "")},
			found: true, total: 9,
		},
		{
			name:  "unparseable timestamp is out of the fold",
			files: []string{tokenLine("yesterday", 9, "")},
		},
		{
			name:  "unknown future field does not break decoding",
			files: []string{`{"timestamp":"2026-04-24T12:00:00.000Z","type":"event_msg","future":1,"payload":{"type":"token_count","info":{"future":"x","total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2}}}}`},
			found: true, total: 2,
		},
		{
			name:  "missing required count rejects the line",
			files: []string{`{"timestamp":"2026-04-24T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}}}`},
		},
		{
			name:  "window missing window_minutes rejects the line",
			files: []string{tokenLine("2026-04-24T12:00:00.000Z", 2, `{"primary":{"used_percent":1}}`)},
		},
		{
			name:  "mistyped unread field rejects the line",
			files: []string{tokenLine("2026-04-24T12:00:00.000Z", 2, `{"plan_type":3}`)},
		},
		{
			name:  "fractional count rejects the line and whole-number float is fine",
			files: []string{`{"timestamp":"2026-04-24T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1.5,"cached_input_tokens":0,"output_tokens":1,"total_tokens":2}}}}` + "\n" + `{"timestamp":"2026-04-24T11:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1,"total_tokens":3.0}}}}`},
			found: true, total: 3,
		},
		{
			name: "limit reached inherits from the same file",
			files: []string{tokenLine("2026-09-08T04:57:57.516Z", 98455, windows) + "\n" +
				tokenLine("2026-09-08T04:58:00.593Z", 98455, `{"limit_id":"premium","primary":null,"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":"plus","rate_limit_reached_type":null}`)},
			found: true, total: 98455, primary: secondaryPct(98), secondary: secondaryPct(15), limitID: "premium",
		},
		{
			name: "limit reached inherits from another file",
			files: []string{
				tokenLine("2026-09-08T08:34:59.878Z", 9199858, `{"limit_id":"premium","primary":null,"secondary":null,"plan_type":"plus"}`),
				tokenLine("2026-09-08T04:00:00.000Z", 2, windows),
			},
			found: true, total: 9199858, primary: secondaryPct(98), secondary: secondaryPct(15), limitID: "premium",
		},
		{
			name: "CLIProxy null windows do not inherit",
			files: []string{
				tokenLine("2026-10-07T02:34:31.992Z", 18404, `{"limit_id":"codex","primary":null,"secondary":null,"plan_type":null,"rate_limit_reached_type":null}`),
				tokenLine("2026-10-06T04:45:10.369Z", 2, `{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1791276293},"secondary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1791774648},"plan_type":"team"}`),
			},
			found: true, total: 18404, limitID: "codex",
		},
		{
			name: "post limit drops a window that already reset",
			files: []string{
				tokenLine("2026-10-06T09:00:00.000Z", 11, `{"limit_id":"premium","primary":null,"secondary":null,"plan_type":"team"}`),
				tokenLine("2026-10-06T04:45:10.369Z", 2, `{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":300,"resets_at":1791276293},"secondary":{"used_percent":42.0,"window_minutes":10080,"resets_at":1791774648},"plan_type":"team"}`),
			},
			found: true, total: 11, secondary: secondaryPct(42), limitID: "premium",
		},
		{
			name: "reached type inherits while limit_id stays codex",
			files: []string{
				tokenLine("2026-09-08T04:30:00.000Z", 22, `{"limit_id":"codex","primary":null,"secondary":null,"plan_type":"plus","rate_limit_reached_type":"primary"}`),
				tokenLine("2026-09-08T04:00:00.000Z", 2, windows),
			},
			found: true, total: 22, primary: secondaryPct(98), secondary: secondaryPct(15), limitID: "codex",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			var paths []string
			for i, contents := range tc.files {
				path := filepath.Join(dir, fmt.Sprintf("%d.jsonl", i))
				if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
					t.Fatal(err)
				}
				paths = append(paths, path)
			}
			fold, found := foldRollouts(paths, utcDay)
			if found != tc.found {
				t.Fatalf("found = %v", found)
			}
			if !found {
				return
			}
			event := fold.last
			if got := event.Payload.Info.TotalTokenUsage.TotalTokens; got != tc.total {
				t.Fatalf("total = %d, want %d", got, tc.total)
			}
			limits := event.Payload.RateLimits
			var primary, secondary *float64
			limitID := ""
			if limits != nil {
				if limits.Primary != nil {
					primary = &limits.Primary.UsedPercent
				}
				if limits.Secondary != nil {
					secondary = &limits.Secondary.UsedPercent
				}
				if limits.LimitID != nil {
					limitID = *limits.LimitID
				}
			}
			if !reflect.DeepEqual(primary, tc.primary) || !reflect.DeepEqual(secondary, tc.secondary) || limitID != tc.limitID {
				t.Fatalf("primary %v secondary %v limit %q", primary, secondary, limitID)
			}
		})
	}
}

func TestLastTokenCountSkipsFileWithInvalidUTF8(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.jsonl")
	if err := os.WriteFile(path, []byte(tokenLine("2026-04-24T12:00:00.000Z", 9, "")+"\n\xff\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, found := foldRollouts([]string{path}, utcDay); found {
		t.Fatal("Swift's String(contentsOf:encoding:) rejects the whole file")
	}
}

func TestRolloutFiles(t *testing.T) {
	cases := []struct {
		name  string
		now   time.Time
		zone  string
		files []string
		want  []string
	}{
		{name: "empty root", now: time.Date(2026, 5, 18, 12, 0, 0, 0, time.UTC), zone: "UTC"},
		{
			name: "today and yesterday only", now: time.Date(2026, 5, 18, 12, 0, 0, 0, time.UTC), zone: "UTC",
			files: []string{"2026/05/18/t.jsonl", "2026/05/17/y.jsonl", "2026/05/16/old.jsonl"},
			want:  []string{"t.jsonl", "y.jsonl"},
		},
		{
			name: "missing yesterday", now: time.Date(2026, 5, 18, 12, 0, 0, 0, time.UTC), zone: "UTC",
			files: []string{"2026/05/18/t.jsonl"},
			want:  []string{"t.jsonl"},
		},
		{
			name: "DST spring forward keeps the civil date", now: time.Date(2026, 3, 8, 20, 0, 0, 0, time.UTC), zone: "America/Los_Angeles",
			files: []string{"2026/03/07/y.jsonl"},
			want:  []string{"y.jsonl"},
		},
		{
			name: "leap day", now: time.Date(2028, 2, 29, 12, 0, 0, 0, time.UTC), zone: "UTC",
			files: []string{"2028/02/28/leap.jsonl"},
			want:  []string{"leap.jsonl"},
		},
		{
			name: "path components are Gregorian, not Buddhist", now: time.Date(2026, 5, 18, 12, 0, 0, 0, time.UTC), zone: "Asia/Bangkok",
			files: []string{"2569/05/18/buddhist.jsonl", "2026/05/18/gregorian.jsonl"},
			want:  []string{"gregorian.jsonl"},
		},
		{
			name: "other extensions and hidden files are ignored", now: time.Date(2026, 5, 18, 12, 0, 0, 0, time.UTC), zone: "UTC",
			files: []string{"2026/05/18/a.jsonl", "2026/05/18/b.txt", "2026/05/18/.hidden.jsonl"},
			want:  []string{"a.jsonl"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			for _, f := range tc.files {
				writeAll(t, filepath.Join(root, filepath.Dir(f)), map[string]string{filepath.Base(f): ""})
			}
			loc, err := time.LoadLocation(tc.zone)
			if err != nil {
				t.Fatal(err)
			}
			today := tc.now.In(loc).Format("2006-01-02")
			yesterday, _ := domain.AddDays(today, -1)
			var got []string
			for _, p := range rolloutFiles(root, []string{today, yesterday}) {
				got = append(got, filepath.Base(p))
			}
			sort.Strings(got)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("files = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestRolloutFilesMissingRootAndSymlinks(t *testing.T) {
	if got := rolloutFiles(filepath.Join(t.TempDir(), "missing"), []string{"2026-05-18"}); got != nil {
		t.Fatalf("missing root = %v", got)
	}
	base := t.TempDir()
	real := filepath.Join(base, "real")
	writeAll(t, filepath.Join(real, "2026", "05", "18"), map[string]string{"a.jsonl": ""})
	link := filepath.Join(base, "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	canonical, err := filepath.EvalSymlinks(filepath.Join(real, "2026", "05", "18", "a.jsonl"))
	if err != nil {
		t.Fatal(err)
	}
	if got := rolloutFiles(link, []string{"2026-05-18"}); len(got) != 1 || got[0] != canonical {
		t.Fatalf("not canonical: %v", got)
	}
}

func TestUsageResponseDecoding(t *testing.T) {
	cases := []struct {
		name    string
		body    string
		wantErr bool
		windows int
		planSet bool
	}{
		{name: "empty object", body: `{}`},
		{name: "primary only", body: `{"rate_limit":{"primary_window":{"used_percent":3,"reset_at":1,"limit_window_seconds":18000}}}`, windows: 1},
		{name: "float percent and unknown fields", body: `{"future":1,"plan_type":"pro","rate_limit":{"future":{},"primary_window":{"used_percent":48.5},"secondary_window":{}}}`, windows: 2, planSet: true},
		{name: "rollout shape does not resolve", body: `{"rate_limits":{"primary":{"used_percent":3,"window_minutes":300}}}`},
		{name: "mistyped percent fails", body: `{"rate_limit":{"primary_window":{"used_percent":"3"}}}`, wantErr: true},
		{name: "fractional reset fails", body: `{"rate_limit":{"primary_window":{"reset_at":1.5}}}`, wantErr: true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var r usageResponse
			err := json.Unmarshal([]byte(tc.body), &r)
			if (err != nil) != tc.wantErr {
				t.Fatalf("err = %v", err)
			}
			if err != nil {
				return
			}
			if got := len(r.windows()); got != tc.windows {
				t.Fatalf("windows = %d", got)
			}
			if (r.PlanType != nil) != tc.planSet {
				t.Fatalf("plan = %v", r.PlanType)
			}
		})
	}
}
