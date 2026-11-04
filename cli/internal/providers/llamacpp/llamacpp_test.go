package llamacpp

import (
	"context"
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
	healthKey = "GET /health"
	modelsKey = "GET /v1/models"
)

var now = time.Unix(1_790_000_000, 0)

func fixture(t *testing.T, name string) httpscript.Reply {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("../../../../AgentsUsageBarTests/ProvidersLlamaCppTests/Fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	return httpscript.JSON(string(data))
}

func TestFetch(t *testing.T) {
	ok, models := fixture(t, "llamacpp-health-ok.json"), fixture(t, "llamacpp-v1-models.json")
	timedOut := httpscript.Fail(domain.NetworkError{Code: domain.NetworkTimedOut, Err: context.DeadlineExceeded})
	base := func(extra map[string]string) map[string]string {
		m := map[string]string{"source": "llamacpp", "port": "8080"}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}
	const gguf = "llama-3-8b-instruct-Q4_K_M.gguf"
	running := base(map[string]string{"modelCount": "1", "modelName": gguf, "allModels": gguf})
	for _, tc := range []struct {
		name           string
		health, models httpscript.Reply
		kind           domain.StatusKind
		raw            map[string]string
	}{
		{"ok with a model", ok, models, domain.StatusOK, running},
		{"loading", fixture(t, "llamacpp-health-loading.json"), models, domain.StatusOK, base(map[string]string{"loadingModel": "true", "modelCount": "0"})},
		{"loading without the model suffix, any case", httpscript.JSON(`{"status":"LOADING"}`), models, domain.StatusOK, base(map[string]string{"loadingModel": "true", "modelCount": "0"})},
		{"error status", fixture(t, "llamacpp-health-error.json"), models, domain.StatusError, base(map[string]string{"modelCount": "0", "note": "degraded"})},
		{"no slot is still running", fixture(t, "llamacpp-health-no-slot.json"), models, domain.StatusOK, running},
		{"unknown status is lenient", httpscript.JSON(`{"status":"warming the flux capacitor"}`), models, domain.StatusOK, running},
		{"missing status is lenient", httpscript.JSON(`{"slots_idle":1}`), models, domain.StatusOK, running},
		{"models failure does not abort health", ok, httpscript.Status(500), domain.StatusOK, base(map[string]string{"modelCount": "0"})},
		{"empty models", ok, httpscript.JSON(`{"data":[]}`), domain.StatusOK, base(map[string]string{"modelCount": "0"})},
		{"null models", ok, httpscript.JSON(`{"data":null}`), domain.StatusOK, base(map[string]string{"modelCount": "0"})},
		{"model without an id", ok, httpscript.JSON(`{"data":[{"object":"model"}]}`), domain.StatusOK, base(map[string]string{"modelCount": "0"})},
		{"basename of a path", ok, httpscript.JSON(`{"data":[{"id":"/foo/bar/baz.gguf"}]}`), domain.StatusOK, base(map[string]string{"modelCount": "1", "modelName": "baz.gguf", "allModels": "baz.gguf"})},
		{"bare name", ok, httpscript.JSON(`{"data":[{"id":"baz"},{"id":"second"}]}`), domain.StatusOK, base(map[string]string{"modelCount": "1", "modelName": "baz", "allModels": "baz"})},
		{"refused", httpscript.Refused(), httpscript.Refused(), domain.StatusNotRunning, base(map[string]string{"modelCount": "0", "providerStatus": "notRunning"})},
		{"timed out", timedOut, timedOut, domain.StatusNotRunning, base(map[string]string{"modelCount": "0", "providerStatus": "notRunning"})},
		{"health 500", httpscript.Status(500), models, domain.StatusError, base(map[string]string{"modelCount": "0", "note": "degraded"})},
	} {
		http := httpscript.New().Script(healthKey, tc.health).Script(modelsKey, tc.models)
		p := newProvider(http, 8080, domain.LlamaCpp, "llama.cpp")
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
		if snap.TokensToday != nil || snap.CostTodayUSD != nil {
			t.Errorf("%s: usage reported", tc.name)
		}
		for _, call := range http.Calls() {
			if call.Bearer != "" {
				t.Errorf("%s: localhost probe sent a bearer", tc.name)
			}
		}
	}
}

func TestDegradedPollKeepsLastPayload(t *testing.T) {
	http := httpscript.New().
		Script(healthKey, fixture(t, "llamacpp-health-ok.json"), httpscript.Status(500)).
		Script(modelsKey, fixture(t, "llamacpp-v1-models.json"))
	p := newProvider(http, 8080, domain.LlamaCpp, "llama.cpp")
	if _, _, err := p.Fetch(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	snap, status, _ := p.Fetch(context.Background(), now.Add(time.Minute))
	if snap.Raw["note"] != "degraded" || snap.Raw["modelName"] == "" || status.Kind != domain.StatusStale {
		t.Errorf("raw %v status %+v", snap.Raw, status)
	}
}

func TestBuildNeedsAPort(t *testing.T) {
	http := httpscript.New().Script(healthKey, httpscript.JSON(`{"status":"ok"}`))
	env := provider.Env{Config: config.Defaults(), LocalhostHTTP: http}
	if built := Build(env); built != nil {
		t.Errorf("built %v without a port", built)
	}
	port := 8123
	env.Config.LlamaCpp.Port = &port
	built := Build(env)
	if built == nil || built.ID() != domain.LlamaCpp || built.DisplayName() != "llama.cpp" {
		t.Fatalf("built %v", built)
	}
	if _, _, err := built.Fetch(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	for _, call := range http.Calls() {
		if call.URL != "http://localhost:8123"+call.Path {
			t.Errorf("url %s", call.URL)
		}
	}
}

func TestBuildEngineUsesItsIdentityAndPort(t *testing.T) {
	http := httpscript.New().Script(healthKey, httpscript.JSON(`{"status":"ok"}`)).Script(modelsKey, httpscript.JSON(`{"data":[]}`))
	built := BuildEngine(provider.Env{LocalhostHTTP: http}, config.LocalEngine{ID: "engine.box", DisplayName: "Box"}, 9001)
	snap, _, err := built.Fetch(context.Background(), now)
	if err != nil {
		t.Fatal(err)
	}
	if built.ID() != "engine.box" || built.DisplayName() != "Box" || snap.ProviderID != "engine.box" || snap.Raw["port"] != "9001" {
		t.Errorf("%v %v %+v", built.ID(), built.DisplayName(), snap)
	}
	if want := (domain.Capabilities{IsLocal: true}); built.Capabilities() != want {
		t.Errorf("caps %+v", built.Capabilities())
	}
}
