package cli

import (
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/swiftjson"
)

var prettyJSON = swiftjson.Options{Pretty: true, WithoutEscapeSlashes: true}

// iso8601 is `.iso8601`: whole seconds in UTC, truncated.
func iso8601(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05Z") }

func quotaTree(q *domain.Quota) map[string]any {
	return map[string]any{"used": q.Used, "limit": q.Limit, "remaining": q.Remaining, "fraction": q.Fraction()}
}

func windowsTree(windows []domain.QuotaWindow) []any {
	out := make([]any, len(windows))
	for i, w := range windows {
		m := map[string]any{"name": w.Name}
		if w.Utilization != nil {
			m["utilization"] = *w.Utilization
		}
		if w.ResetsAt != nil {
			m["resetsAt"] = iso8601(*w.ResetsAt)
		}
		out[i] = m
	}
	return out
}

func putQuotaFields(m map[string]any, q *domain.Quota, windows []domain.QuotaWindow) {
	if q != nil {
		m["quota"] = quotaTree(q)
	}
	if windows != nil {
		m["quotaWindows"] = windowsTree(windows)
	}
}

func accountTree(a domain.AccountUsage, nullCost bool) map[string]any {
	m := map[string]any{"name": a.Name}
	if a.CostTodayUSD != nil {
		m["costTodayUSD"] = a.CostTodayUSD.String()
	} else if nullCost {
		m["costTodayUSD"] = nil
	}
	putQuotaFields(m, a.Quota, a.QuotaWindows)
	return m
}

func providerTree(p ProviderReport) map[string]any {
	m := map[string]any{"id": string(p.ID), "displayName": p.DisplayName, "status": string(p.Status.Kind)}
	raw := map[string]any{}
	var accounts []domain.AccountUsage
	if s := p.Snapshot; s != nil {
		if s.TokensToday != nil {
			m["tokensToday"] = *s.TokensToday
		}
		if s.CostTodayUSD != nil {
			m["costTodayUSD"] = s.CostTodayUSD.String()
		}
		if s.BalanceUSD != nil {
			m["balanceUSD"] = s.BalanceUSD.String()
		}
		putQuotaFields(m, s.Quota, s.QuotaWindows)
		for k, v := range s.Raw {
			raw[k] = v
		}
		accounts = s.Accounts
	}
	switch {
	case p.ID == domain.Codex && len(accounts) < 2:
		m["accounts"] = nil
	case accounts != nil:
		rows := make([]any, len(accounts))
		for i, a := range accounts {
			rows[i] = accountTree(a, p.ID == domain.Codex)
		}
		m["accounts"] = rows
	}
	m["raw"] = raw
	if p.ErrorDescription != nil {
		m["error"] = *p.ErrorDescription
	}
	return m
}

func renderUsageJSON(report UsageReport) string {
	totals := report.Totals()
	providers := make([]any, len(report.Providers))
	for i, p := range report.Providers {
		providers[i] = providerTree(p)
	}
	doc := map[string]any{
		"asOf":      iso8601(report.AsOf),
		"source":    string(report.Source),
		"totals":    map[string]any{"tokens": totals.Tokens, "costUSD": totals.CostUSD.String()},
		"providers": providers,
	}
	return swiftjson.Encode(doc, prettyJSON) + "\n"
}

func renderQuotaJSON(report UsageReport) string {
	rows := make([]any, len(report.Providers))
	for i, p := range report.Providers {
		m := map[string]any{"id": string(p.ID), "status": string(p.Status.Kind)}
		if s := p.Snapshot; s != nil {
			putQuotaFields(m, s.Quota, s.QuotaWindows)
			if p.ID == domain.Codex && len(s.Accounts) >= 2 {
				accounts := make([]any, len(s.Accounts))
				for j, a := range s.Accounts {
					row := map[string]any{"name": a.Name}
					putQuotaFields(row, a.Quota, a.QuotaWindows)
					accounts[j] = row
				}
				m["accounts"] = accounts
			}
		}
		if p.ErrorDescription != nil {
			m["error"] = *p.ErrorDescription
		}
		rows[i] = m
	}
	return swiftjson.Encode(rows, prettyJSON) + "\n"
}
