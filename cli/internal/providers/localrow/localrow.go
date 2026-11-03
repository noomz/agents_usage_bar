// Package localrow is the row state shared by localhost runtimes: a stopped server is a muted
// snapshot, a failing one is a degraded snapshot, and Fetch never returns an error.
package localrow

import (
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

// Row holds a runtime's identity, its status, and its last snapshot.
type Row struct {
	id     domain.ProviderID
	name   string
	base   map[string]string
	status domain.ProviderStatus
	last   *domain.UsageSnapshot
}

// New starts a row as not running. base is the raw payload every snapshot carries.
func New(id domain.ProviderID, name string, base map[string]string) *Row {
	return &Row{id: id, name: name, base: base, status: domain.NotRunning()}
}

// ID implements provider.Provider.
func (r *Row) ID() domain.ProviderID { return r.id }

// DisplayName implements provider.Provider.
func (r *Row) DisplayName() string { return r.name }

// Capabilities implements provider.Provider: local rows report no quota, cost, or tokens.
func (r *Row) Capabilities() domain.Capabilities { return domain.Capabilities{IsLocal: true} }

// Status implements provider.Provider.
func (r *Row) Status() domain.ProviderStatus { return r.status }

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
func (r *Row) OK(now time.Time, extra map[string]string) domain.UsageSnapshot {
	r.status = domain.OK(now)
	snap := r.snapshot(now, r.raw(extra))
	r.last = &snap
	return snap
}

// Failed records a failed probe. A transport failure means the runtime is not running; anything
// else degrades the row.
func (r *Row) Failed(now time.Time, err error) domain.UsageSnapshot {
	if domain.ClassifyLocalhost(err, nil).Kind == domain.StatusNotRunning {
		r.status = domain.NotRunning()
		snap := r.snapshot(now, r.raw(map[string]string{"modelCount": "0", domain.RawProviderStatus: domain.StatusSentinelNotRunning}))
		r.last = &snap
		return snap
	}
	return r.Degraded(now, err)
}

// Degraded reuses the last snapshot's payload when there is one.
func (r *Row) Degraded(now time.Time, err error) domain.UsageSnapshot {
	pe := domain.ProviderErrorFrom(err)
	if r.last != nil {
		r.status = domain.Stale(now, pe)
		raw := make(map[string]string, len(r.last.Raw)+1)
		for k, v := range r.last.Raw {
			raw[k] = v
		}
		raw["note"] = "degraded"
		return r.snapshot(now, raw)
	}
	r.status = domain.Errored(pe)
	return r.snapshot(now, r.raw(map[string]string{"modelCount": "0", "note": "degraded"}))
}
