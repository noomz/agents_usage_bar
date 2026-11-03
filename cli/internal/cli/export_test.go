package cli

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

var exportedAt = time.Unix(1_773_500_000, 0)

func exportHistory() []domain.DayFile { return syntheticDays(statsToday, 7) }

func exportScopeOf(t *testing.T, days int) exportScope {
	t.Helper()
	return exportScope{statsRange: statsRangeOf(t, &days, nil, nil)}
}

func parseExport(t *testing.T, days []domain.DayFile, scope exportScope) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal([]byte(renderExportJSON(days, scope, exportedAt)), &out); err != nil {
		t.Fatal(err)
	}
	return out
}

func exportedDays(doc map[string]any) []map[string]any {
	items := doc["days"].([]any)
	out := make([]map[string]any, len(items))
	for i, d := range items {
		out[i] = d.(map[string]any)
	}
	return out
}

func recordOf(t *testing.T, d map[string]any, id string) map[string]any {
	t.Helper()
	for _, r := range d["records"].([]any) {
		if m := r.(map[string]any); m["provider"] == id {
			return m
		}
	}
	t.Fatalf("no record %s", id)
	return nil
}

func TestExportTopLevel(t *testing.T) {
	doc := parseExport(t, exportHistory(), exportScopeOf(t, 7))
	if len(doc) != 4 || doc["schemaVersion"].(float64) != 1 {
		t.Errorf("%v", doc)
	}
	rng := doc["range"].(map[string]any)
	if rng["from"] != "2026-03-08" || rng["to"] != "2026-03-14" {
		t.Errorf("%v", rng)
	}
	text := renderExportJSON(exportHistory(), exportScopeOf(t, 7), exportedAt)
	for _, private := range []string{"backfillChecked", "salt", "budget"} {
		if strings.Contains(text, private) {
			t.Errorf("exports %s", private)
		}
	}
}

func TestExportTodayUnsealed(t *testing.T) {
	all := exportedDays(parseExport(t, exportHistory(), exportScopeOf(t, 7)))
	for i, d := range all {
		if want := i < len(all)-1; d["sealed"] != want {
			t.Errorf("%v sealed=%v", d["date"], d["sealed"])
		}
	}
	if all[len(all)-1]["date"] != statsToday {
		t.Error("last day")
	}
}

func TestValueIsNotSpend(t *testing.T) {
	d := exportedDays(parseExport(t, exportHistory(), exportScopeOf(t, 7)))[0]
	claude := recordOf(t, d, "claude")
	if claude["costUSD"] != nil || claude["valueUSD"] != "5" {
		t.Errorf("%v", claude)
	}
	or := recordOf(t, d, "openrouter")
	if _, isString := or["costUSD"].(string); !isString || or["valueUSD"] != nil {
		t.Errorf("%v", or)
	}
}

func TestUnknownIsNull(t *testing.T) {
	d := exportedDays(parseExport(t, exportHistory(), exportScopeOf(t, 7)))[0]
	ollama := recordOf(t, d, "ollama")
	for _, key := range []string{"tokens", "costUSD", "balanceUSD"} {
		if v, present := ollama[key]; !present || v != nil {
			t.Errorf("%s: %v", key, v)
		}
	}
}

func TestAccountFields(t *testing.T) {
	d := exportedDays(parseExport(t, exportHistory(), exportScopeOf(t, 7)))[0]
	for _, a := range recordOf(t, d, "claude")["accounts"].([]any) {
		m := a.(map[string]any)
		if len(m) != 4 || m["key"] == nil || m["label"] == nil || m["billingModel"] == nil {
			t.Errorf("%v", m)
		}
	}
}

func strs(v any) string {
	var out []string
	for _, item := range v.([]any) {
		out = append(out, item.(string))
	}
	return strings.Join(out, ",")
}

func TestGaps(t *testing.T) {
	all := exportedDays(parseExport(t, exportHistory(), exportScopeOf(t, 7)))
	if got := strs(all[len(all)-1]["gaps"]); got != "claude" {
		t.Error(got)
	}
	scope := exportScopeOf(t, 7)
	scope.isEnabled = func(id domain.ProviderID) bool { return id != domain.Claude }
	all = exportedDays(parseExport(t, exportHistory(), scope))
	if got := strs(all[len(all)-1]["gaps"]); got != "" {
		t.Error(got)
	}
}

func TestMissingDayFile(t *testing.T) {
	n := 3
	r, err := ResolveRange("2026-03-15", &n, nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	all := exportedDays(parseExport(t, exportHistory(), exportScope{statsRange: r}))
	last := all[len(all)-1]
	if v, present := last["timeZone"]; !present || v != nil {
		t.Errorf("zone %v", v)
	}
	if got := strs(last["gaps"]); got != "claude,codex,ollama,openrouter" {
		t.Error(got)
	}
}

func TestProviderScope(t *testing.T) {
	claude := domain.Claude
	scope := exportScopeOf(t, 7)
	scope.provider = &claude
	all := exportedDays(parseExport(t, exportHistory(), scope))
	for _, d := range all {
		for _, r := range d["records"].([]any) {
			if r.(map[string]any)["provider"] != "claude" {
				t.Errorf("%v", r)
			}
		}
	}
	if got := strs(all[len(all)-1]["gaps"]); got != "claude" {
		t.Error(got)
	}
	codex := domain.Codex
	scope.provider = &codex
	for _, d := range exportedDays(parseExport(t, exportHistory(), scope)) {
		if len(d["events"].([]any)) != 0 {
			t.Errorf("%v", d["events"])
		}
	}
}

func TestDefaultExportRangeIsAllRetained(t *testing.T) {
	oldest := "2026-03-08"
	r, err := ResolveRange(statsToday, nil, nil, nil, &oldest)
	if err != nil || r.Keys[0] != oldest || len(r.Keys) != 7 {
		t.Errorf("%v %v", r, err)
	}
	n := 2
	r, err = ResolveRange(statsToday, &n, nil, nil, &oldest)
	if err != nil || strings.Join(r.Keys, ",") != "2026-03-13,2026-03-14" {
		t.Errorf("%v %v", r, err)
	}
}

func TestCSVHeaders(t *testing.T) {
	for table, columns := range csvColumns {
		header := lines(renderExportCSV(exportHistory(), exportScopeOf(t, 7), table))[0]
		if header != strings.Join(columns, ",") {
			t.Errorf("%s: %s", table, header)
		}
	}
}

func TestCSVCells(t *testing.T) {
	var rows [][]string
	for _, l := range lines(renderExportCSV(exportHistory(), exportScopeOf(t, 7), CSVDays)) {
		rows = append(rows, strings.Split(l, ","))
	}
	find := func(id string) []string {
		for _, r := range rows {
			if r[1] == id {
				return r
			}
		}
		t.Fatalf("no %s", id)
		return nil
	}
	for _, r := range rows {
		if r[0] == statsToday && r[1] == "claude" {
			t.Error("a gap must be a missing row")
		}
	}
	ollama := find("ollama")
	if ollama[2] != "" || ollama[3] != "" || ollama[6] != "" || ollama[7] != "local" {
		t.Errorf("%v", ollama)
	}
	claude := find("claude")
	if claude[3] != "" || claude[4] != "5" {
		t.Errorf("%v", claude)
	}
	if find("codex")[7] != "mixed" {
		t.Error("codex billing")
	}
	if rows[len(rows)-1][9] != "false" {
		t.Error("today sealed")
	}
}

func TestQuotaTableRows(t *testing.T) {
	codex := domain.Codex
	scope := exportScopeOf(t, 1)
	scope.provider = &codex
	rows := lines(renderExportCSV(exportHistory(), scope, CSVQuota))
	if len(rows) != 2 || !strings.HasPrefix(rows[1], "2026-03-14,codex,,5h,0.5,,0.25") {
		t.Errorf("%v", rows)
	}
}

func TestCSVEscaping(t *testing.T) {
	d := exportHistory()[0]
	d.Records = []domain.DayRecord{{Provider: domain.Claude, Origin: domain.OriginObserved, Accounts: []domain.DayAccount{
		{Key: "a,b", Label: `say "hi"`, BillingModel: domain.BillingSubscription},
	}}}
	n := 1
	r, err := ResolveRange(d.Date, &n, nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	got := lines(renderExportCSV([]domain.DayFile{d}, exportScope{statsRange: r}, CSVAccounts))[1]
	if want := d.Date + `,claude,"a,b","say ""hi""",subscription,`; got != want {
		t.Errorf("%s", got)
	}
}
