package ollama

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/httpscript"
)

var now = time.Unix(1_790_000_000, 0)

func fixture(t *testing.T, name string) httpscript.Reply {
	t.Helper()
	data, err := os.ReadFile(filepath.Join("../../../../AgentsUsageBarTests/ProvidersOllamaTests/Fixtures", name))
	if err != nil {
		t.Fatal(err)
	}
	return httpscript.JSON(string(data))
}

func TestFetch(t *testing.T) {
	single, multi, psEmpty := fixture(t, "ollama-ps-single-model.json"), fixture(t, "ollama-ps-multi-model.json"), fixture(t, "ollama-ps-empty.json")
	tags, tagsEmpty := fixture(t, "ollama-tags-non-empty.json"), fixture(t, "ollama-tags-empty.json")
	timedOut := httpscript.Fail(domain.NetworkError{Code: domain.NetworkTimedOut, Err: context.DeadlineExceeded})
	for _, tc := range []struct {
		name     string
		ps, tags httpscript.Reply
		kind     domain.StatusKind
		raw      map[string]string
	}{
		{"single model", single, tags, domain.StatusOK, map[string]string{"source": "ollama", "modelCount": "1", "modelName": "llama3:8b", "vramBytes": "5137025024", "allModels": "llama3:8b"}},
		{"multiple models", multi, tags, domain.StatusOK, map[string]string{"source": "ollama", "modelCount": "3", "modelName": "llama3:8b", "allModels": "llama3:8b|mistral:7b|phi3:mini"}},
		{"idle with models installed", psEmpty, tags, domain.StatusOK, map[string]string{"source": "ollama", "modelCount": "0", "installedCount": "2"}},
		{"idle with nothing installed", psEmpty, tagsEmpty, domain.StatusOK, map[string]string{"source": "ollama", "modelCount": "0", "installedCount": "0"}},
		{"tags failure does not abort ps", single, httpscript.Status(500), domain.StatusOK, map[string]string{"source": "ollama", "modelCount": "1", "modelName": "llama3:8b", "vramBytes": "5137025024", "allModels": "llama3:8b"}},
		{"tags failure while idle", psEmpty, httpscript.Status(500), domain.StatusOK, map[string]string{"source": "ollama", "modelCount": "0", "installedCount": "0"}},
		{"tag without a name counts as a tags failure", psEmpty, httpscript.JSON(`{"models":[{"size":1}]}`), domain.StatusOK, map[string]string{"source": "ollama", "modelCount": "0", "installedCount": "0"}},
		{"null models", httpscript.JSON(`{"models":null}`), httpscript.JSON(`{}`), domain.StatusOK, map[string]string{"source": "ollama", "modelCount": "0", "installedCount": "0"}},
		{"unknown fields and no size_vram", httpscript.JSON(`{"surprise":1,"models":[{"name":"m","future":{"a":[1]}}]}`), tags, domain.StatusOK, map[string]string{"source": "ollama", "modelCount": "1", "modelName": "m", "vramBytes": "0", "allModels": "m"}},
		{"size_vram past 32 bits", httpscript.JSON(`{"models":[{"name":"m","size_vram":54975581388800}]}`), tags, domain.StatusOK, map[string]string{"source": "ollama", "modelCount": "1", "modelName": "m", "vramBytes": "54975581388800", "allModels": "m"}},
		{"refused", httpscript.Refused(), httpscript.Refused(), domain.StatusNotRunning, map[string]string{"source": "ollama", "modelCount": "0", "providerStatus": "notRunning"}},
		{"timed out", timedOut, timedOut, domain.StatusNotRunning, map[string]string{"source": "ollama", "modelCount": "0", "providerStatus": "notRunning"}},
		{"http 500", httpscript.Status(500), tagsEmpty, domain.StatusError, map[string]string{"source": "ollama", "modelCount": "0", "note": "degraded"}},
		{"model without a name fails ps", httpscript.JSON(`{"models":[{"size_vram":1}]}`), tags, domain.StatusError, map[string]string{"source": "ollama", "modelCount": "0", "note": "degraded"}},
		{"not json", httpscript.JSON(`nope`), tags, domain.StatusError, map[string]string{"source": "ollama", "modelCount": "0", "note": "degraded"}},
	} {
		http := httpscript.New().Script("GET /api/ps", tc.ps).Script("GET /api/tags", tc.tags)
		p := newProvider(http)
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
		if snap.ProviderID != domain.Ollama || !snap.AsOf.Equal(now) || snap.TokensToday != nil || snap.CostTodayUSD != nil {
			t.Errorf("%s: snapshot %+v", tc.name, snap)
		}
		for _, call := range http.Calls() {
			if call.Bearer != "" {
				t.Errorf("%s: localhost probe sent a bearer", tc.name)
			}
		}
	}
}

func TestDegradedPollKeepsLastPayload(t *testing.T) {
	http := httpscript.New().Script("GET /api/ps", fixture(t, "ollama-ps-single-model.json"), httpscript.Status(500)).Script("GET /api/tags", httpscript.JSON(`{}`))
	p := newProvider(http)
	if _, _, err := p.Fetch(context.Background(), now); err != nil {
		t.Fatal(err)
	}
	snap, status, _ := p.Fetch(context.Background(), now.Add(time.Minute))
	if snap.Raw["note"] != "degraded" || snap.Raw["modelName"] != "llama3:8b" {
		t.Errorf("raw %v", snap.Raw)
	}
	if status.Kind != domain.StatusStale {
		t.Errorf("status %+v", status)
	}
}

func TestIdentity(t *testing.T) {
	p := newProvider(httpscript.New())
	if p.ID() != domain.Ollama || p.DisplayName() != "Ollama" {
		t.Errorf("%v %v", p.ID(), p.DisplayName())
	}
	if want := (domain.Capabilities{IsLocal: true}); p.Capabilities() != want {
		t.Errorf("caps %+v", p.Capabilities())
	}
}
