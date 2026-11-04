package lmstudio

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/config"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/httpscript"
)

const (
	v0 = "GET /api/v0/models"
	v1 = "GET /v1/models"
)

var now = time.Unix(1_790_000_000, 0)

func fixture(t *testing.T, name string) httpscript.Reply {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("../../../../AgentsUsageBarTests/ProvidersLMStudioTests/Fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	return httpscript.JSON(string(data))
}

func TestFetch(t *testing.T) {
	timedOut := httpscript.Fail(domain.NetworkError{Code: domain.NetworkTimedOut, Err: context.DeadlineExceeded})
	refused := httpscript.Refused()
	base := func(extra map[string]string) map[string]string {
		m := map[string]string{"source": "lmstudio", "port": "1234"}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	notRunning := base(map[string]string{"modelCount": "0", "providerStatus": "notRunning"})
	degraded := base(map[string]string{"modelCount": "0", "note": "degraded"})
	for _, tc := range []struct {
		name    string
		v0      httpscript.Reply
		v1      *httpscript.Reply
		v1Calls int
		kind    domain.StatusKind
		raw     map[string]string
	}{
		{"one loaded", httpscript.JSON(`{"data":[{"id":"m1","state":"loaded","arch":"a"},{"id":"m2","state":"not-loaded"}]}`), nil, 0, domain.StatusOK, base(map[string]string{"modelCount": "1", "modelName": "m1", "allModels": "m1"})},
		{"mixed state fixture", fixture(t, "lmstudio-v0-models-mixed-state.json"), nil, 0, domain.StatusOK, base(map[string]string{"modelCount": "1", "modelName": "meta-llama-3.1-8b", "allModels": "meta-llama-3.1-8b"})},
		{"all loaded fixture", fixture(t, "lmstudio-v0-models-all-loaded.json"), nil, 0, domain.StatusOK, base(map[string]string{"modelCount": "2", "modelName": "meta-llama-3.1-8b", "allModels": "meta-llama-3.1-8b|phi-3-mini"})},
		{"none loaded fixture", fixture(t, "lmstudio-v0-models-none-loaded.json"), nil, 0, domain.StatusOK, base(map[string]string{"modelCount": "0", "installedCount": "2"})},
		{"no state means loaded", httpscript.JSON(`{"data":[{"id":"old"}]}`), nil, 0, domain.StatusOK, base(map[string]string{"modelCount": "1", "modelName": "old", "allModels": "old"})},
		{"empty data", httpscript.JSON(`{"object":"list","data":[]}`), nil, 0, domain.StatusOK, base(map[string]string{"modelCount": "0", "installedCount": "0"})},
		{"404 falls back", httpscript.Status(404), ptr(fixture(t, "lmstudio-v1-models-fallback.json")), 1, domain.StatusOK, base(map[string]string{"modelCount": "1", "modelName": "meta-llama-3.1-8b", "allModels": "meta-llama-3.1-8b"})},
		{"500 falls back", httpscript.Status(500), ptr(httpscript.JSON(`{"data":[]}`)), 1, domain.StatusOK, base(map[string]string{"modelCount": "0", "installedCount": "0"})},
		{"undecodable v0 falls back", httpscript.JSON(`{"data":[{"state":"loaded"}]}`), ptr(httpscript.JSON(`{"data":[{"id":"x"}]}`)), 1, domain.StatusOK, base(map[string]string{"modelCount": "1", "modelName": "x", "allModels": "x"})},
		{"refused never tries v1", refused, nil, 0, domain.StatusNotRunning, notRunning},
		{"timed out never tries v1", timedOut, nil, 0, domain.StatusNotRunning, notRunning},
		{"v0 500, v1 refused", httpscript.Status(500), &refused, 1, domain.StatusNotRunning, notRunning},
		{"v0 500, v1 500", httpscript.Status(500), ptr(httpscript.Status(500)), 1, domain.StatusError, degraded},
	} {
		http := httpscript.New().Script(v0, tc.v0)
		if tc.v1 != nil {
			http.Script(v1, *tc.v1)
		}
		p := newProvider(http, 1234)
		snap, status, err := p.Fetch(context.Background(), now)
		if err != nil {
			t.Errorf("%s: fetch returned %v", tc.name, err)
		}
		if status.Kind != tc.kind {
			t.Errorf("%s: status %+v", tc.name, status)
		}
		if !reflect.DeepEqual(snap.Raw, tc.raw) {
			t.Errorf("%s: raw %v", tc.name, snap.Raw)
		}
		if got := http.Count(v1); got != tc.v1Calls {
			t.Errorf("%s: %d v1 calls", tc.name, got)
		}
		for _, call := range http.Calls() {
			if call.Bearer != "" {
				t.Errorf("%s: localhost probe sent a bearer", tc.name)
			}
		}
	}
}

func ptr(r httpscript.Reply) *httpscript.Reply { return &r }

func TestPortReachesURLAndRaw(t *testing.T) {
	for _, port := range []int{1234, 4321} {
		http := httpscript.New().Script(v0, httpscript.JSON(`{"data":[]}`))
		var env provider.Env
		env.LocalhostHTTP = http
		env.Config = config.Defaults()
		env.Config.LMStudio.Port = port
		built := Build(env)
		snap, _, _ := built.Fetch(context.Background(), now)
		if want := fmt.Sprintf("http://localhost:%d/api/v0/models", port); http.Calls()[0].URL != want {
			t.Errorf("url %s", http.Calls()[0].URL)
		}
		if snap.Raw["port"] != fmt.Sprint(port) {
			t.Errorf("raw %v", snap.Raw)
		}
	}
}

func TestIdentity(t *testing.T) {
	p := newProvider(httpscript.New(), 1234)
	if p.ID() != domain.LMStudio || p.DisplayName() != "LM Studio" {
		t.Errorf("%v %v", p.ID(), p.DisplayName())
	}
	if want := (domain.Capabilities{IsLocal: true}); p.Capabilities() != want {
		t.Errorf("caps %+v", p.Capabilities())
	}
}
