package localrow

import (
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
)

var now = time.Unix(1_790_000_000, 0)

func TestFailureStates(t *testing.T) {
	network := func(code domain.NetworkErrorCode) error { return domain.NetworkError{Code: code, Err: errors.New("x")} }
	base := map[string]string{"source": "s"}
	notRunning := map[string]string{"source": "s", "modelCount": "0", "providerStatus": "notRunning"}
	degraded := map[string]string{"source": "s", "modelCount": "0", "note": "degraded"}
	for _, tc := range []struct {
		name   string
		err    error
		kind   domain.StatusKind
		raw    map[string]string
		errKnd domain.ProviderErrorKind
	}{
		{"refused", network(domain.NetworkCannotConnect), domain.StatusNotRunning, notRunning, ""},
		{"timed out", network(domain.NetworkTimedOut), domain.StatusNotRunning, notRunning, ""},
		{"no host", network(domain.NetworkCannotFindHost), domain.StatusNotRunning, notRunning, ""},
		{"connection lost", network(domain.NetworkConnectionLost), domain.StatusNotRunning, notRunning, ""},
		{"other transport", network(domain.NetworkOther), domain.StatusError, degraded, domain.ErrNetwork},
		{"http 500", domain.HTTPError{Status: 500}, domain.StatusError, degraded, domain.ErrHTTP},
		{"decode", domain.DecodeError{Err: errors.New("x")}, domain.StatusError, degraded, domain.ErrDecode},
	} {
		r := New("x", "X", base)
		snap := r.Failed(now, tc.err)
		if r.Status().Kind != tc.kind || r.Status().Err.Kind != tc.errKnd {
			t.Errorf("%s: status %+v", tc.name, r.Status())
		}
		if !reflect.DeepEqual(snap.Raw, tc.raw) {
			t.Errorf("%s: raw %v", tc.name, snap.Raw)
		}
		if snap.TokensToday != nil || snap.CostTodayUSD != nil || snap.Quota != nil || snap.QuotaWindows != nil {
			t.Errorf("%s: a local row reports usage: %+v", tc.name, snap)
		}
	}
}

func TestDegradedReusesLastSnapshot(t *testing.T) {
	r := New("x", "X", map[string]string{"source": "s"})
	r.OK(now, map[string]string{"modelCount": "1", "modelName": "m"})
	if r.Status().Kind != domain.StatusOK {
		t.Fatalf("status %+v", r.Status())
	}
	later := now.Add(time.Minute)
	snap := r.Failed(later, domain.HTTPError{Status: 500})
	want := map[string]string{"source": "s", "modelCount": "1", "modelName": "m", "note": "degraded"}
	if !reflect.DeepEqual(snap.Raw, want) {
		t.Errorf("raw %v", snap.Raw)
	}
	if s := r.Status(); s.Kind != domain.StatusStale || !s.LastSuccess.Equal(later) {
		t.Errorf("status %+v", s)
	}
}

func TestInitialStatusAndCapabilities(t *testing.T) {
	r := New("x", "X", nil)
	if r.Status().Kind != domain.StatusNotRunning {
		t.Errorf("status %+v", r.Status())
	}
	if want := (domain.Capabilities{IsLocal: true}); r.Capabilities() != want {
		t.Errorf("caps %+v", r.Capabilities())
	}
}
