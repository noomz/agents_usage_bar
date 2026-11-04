// Package localrow is the row state shared by localhost runtimes: a stopped server is a muted
// snapshot, a failing one is a degraded snapshot, and Fetch never returns an error.
package localrow

import (
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

// Row holds a runtime's identity and its last snapshot. OK, Failed, and Degraded return what
// Fetch returns, so a provider returns them directly.
type Row struct {
	id   domain.ProviderID
	name string
	base map[string]string
	last *domain.UsageSnapshot
}

// New builds a row. base is the raw payload every snapshot carries.
func New(id domain.ProviderID, name string, base map[string]string) *Row {
	return &Row{id: id, name: name, base: base}
}

func (r *Row) ID() domain.ProviderID { return r.id }

func (r *Row) DisplayName() string { return r.name }

// Local rows report no quota, cost, or tokens.
func (r *Row) Capabilities() domain.Capabilities { return domain.Capabilities{IsLocal: true} }

func (r *Row) raw(extra map[string]string) map[string]string {
	out := make(map[string]string, len(r.base)+len(extra))
	for k, v := range r.base {
		out[k] = v
	}
	for k, v := range extra {
		out[k] = v
	}
	return out
}

func (r *Row) snapshot(now time.Time, raw map[string]string) domain.UsageSnapshot {
	return domain.UsageSnapshot{ProviderID: r.id, AsOf: now, Raw: raw}
}

// OK records a good probe.
func (r *Row) OK(now time.Time, extra map[string]string) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	snap := r.snapshot(now, r.raw(extra))
	r.last = &snap
	return snap, domain.OK(now), nil
}

// Failed records a failed probe. A transport failure means the runtime is not running; anything
// else degrades the row.
func (r *Row) Failed(now time.Time, err error) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	if domain.ClassifyLocalhost(err, nil).Kind == domain.StatusNotRunning {
		snap := r.snapshot(now, r.raw(map[string]string{"modelCount": "0", domain.RawProviderStatus: domain.StatusSentinelNotRunning}))
		r.last = &snap
		return snap, domain.NotRunning(), nil
	}
	return r.Degraded(now, err)
}

// Degraded reuses the last snapshot's payload when there is one.
func (r *Row) Degraded(now time.Time, err error) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	pe := domain.ProviderErrorFrom(err)
	if r.last != nil {
		raw := make(map[string]string, len(r.last.Raw)+1)
		for k, v := range r.last.Raw {
			raw[k] = v
		}
		raw["note"] = "degraded"
		return r.snapshot(now, raw), domain.Stale(now, pe), nil
	}
	return r.snapshot(now, r.raw(map[string]string{"modelCount": "0", "note": "degraded"})), domain.Errored(pe), nil
}
