// Package llamacpp reports llama.cpp-compatible servers: the `[llamacpp]` row and every
// `[engine.*]` row.
package llamacpp

import (
	"context"
	"fmt"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/config"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/httpclient"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/localrow"
)

type healthResponse struct {
	Status *string `json:"status"`
}

func (h healthResponse) lowered() string {
	if h.Status == nil {
		return ""
	}
	return strings.ToLower(*h.Status)
}

type modelsResponse struct {
	Data []struct {
		ID *string `json:"id"`
	} `json:"data"`
}

// basename is the first model's file name, or "" when none is listed. A model without an id
// fails the whole response, as Swift's decoder does.
func (m modelsResponse) basename() string {
	for _, d := range m.Data {
		if d.ID == nil {
			return ""
		}
	}
	if len(m.Data) == 0 || *m.Data[0].ID == "" {
		return ""
	}
	return path.Base(*m.Data[0].ID)
}

// Provider probes /health, which drives the status, and /v1/models, which names the model.
type Provider struct {
	*localrow.Row
	http httpclient.Client
	port int
}

// Build registers the `[llamacpp]` row. No port means no live row: the app never scans ports.
func Build(env provider.Env) provider.Provider {
	if env.Config.LlamaCpp.Port == nil {
		return nil
	}
	return newProvider(env.LocalhostHTTP, *env.Config.LlamaCpp.Port, domain.LlamaCpp, "llama.cpp")
}

// BuildEngine registers an `[engine.*]` row on its resolved port.
func BuildEngine(env provider.Env, engine config.LocalEngine, port int) provider.Provider {
	return newProvider(env.LocalhostHTTP, port, engine.ID, engine.DisplayName)
}

func newProvider(http httpclient.Client, port int, id domain.ProviderID, name string) *Provider {
	base := map[string]string{"source": "llamacpp", "port": strconv.Itoa(port)}
	return &Provider{Row: localrow.New(id, name, base), http: http, port: port}
}

func (p *Provider) url(route string) string {
	return fmt.Sprintf("http://localhost:%d%s", p.port, route)
}

func (p *Provider) Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	var health healthResponse
	var models modelsResponse
	var healthErr, modelsErr error
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); healthErr = p.http.GetJSON(ctx, p.url("/health"), nil, nil, &health) }()
	go func() { defer wg.Done(); modelsErr = p.http.GetJSON(ctx, p.url("/v1/models"), nil, nil, &models) }()
	wg.Wait()

	if healthErr != nil {
		return p.Failed(now, healthErr)
	}
	status := health.lowered()
	switch {
	case strings.Contains(status, "loading"):
		return p.OK(now, map[string]string{"loadingModel": "true", "modelCount": "0"})
	case status == "error":
		return p.Degraded(now, domain.ProviderError{Kind: domain.ErrHTTP, Message: "llamacpp /health status: error"})
	}

	raw := map[string]string{"modelCount": "0"}
	if modelsErr == nil {
		if name := models.basename(); name != "" {
			raw = map[string]string{"modelCount": "1", "modelName": name, "allModels": name}
		}
	}
	return p.OK(now, raw)
}
