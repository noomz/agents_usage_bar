// Package lmstudio reports the localhost LM Studio server.
package lmstudio

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/httpclient"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/localrow"
)

type model struct {
	ID *string `json:"id"`
	// State is absent on builds before 0.3.5 and in /v1/models, which means loaded.
	State *string `json:"state"`
}

type modelsResponse struct {
	Data []model `json:"data"`
}

func (r modelsResponse) validate() error {
	for _, m := range r.Data {
		if m.ID == nil {
			return domain.DecodeError{Err: errors.New("model without id")}
		}
	}
	return nil
}

func (r modelsResponse) loaded() []string {
	var ids []string
	for _, m := range r.Data {
		if m.State == nil || *m.State == "loaded" {
			ids = append(ids, *m.ID)
		}
	}
	return ids
}

// Provider probes /api/v0/models, then /v1/models when that endpoint answers with an error.
type Provider struct {
	*localrow.Row
	http httpclient.Client
	port int
}

// Build always registers: a stopped server is a row state, not an absence.
func Build(env provider.Env) provider.Provider {
	return newProvider(env.LocalhostHTTP, env.Config.LMStudio.Port)
}

func newProvider(http httpclient.Client, port int) *Provider {
	base := map[string]string{"source": "lmstudio", "port": strconv.Itoa(port)}
	return &Provider{Row: localrow.New(domain.LMStudio, "LM Studio", base), http: http, port: port}
}

func (p *Provider) get(ctx context.Context, path string) (modelsResponse, error) {
	var r modelsResponse
	err := p.http.GetJSON(ctx, fmt.Sprintf("http://localhost:%d%s", p.port, path), nil, nil, &r)
	if err == nil {
		err = r.validate()
	}
	return r, err
}

func (p *Provider) Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	r, err := p.get(ctx, "/api/v0/models")
	if err == nil {
		return p.row(now, r)
	}
	var network domain.NetworkError
	if errors.As(err, &network) {
		return p.Failed(now, err)
	}
	r, err = p.get(ctx, "/v1/models")
	if err != nil {
		return p.Failed(now, err)
	}
	return p.row(now, r)
}

func (p *Provider) row(now time.Time, r modelsResponse) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	loaded := r.loaded()
	raw := map[string]string{"modelCount": strconv.Itoa(len(loaded))}
	if len(loaded) == 0 {
		raw["installedCount"] = strconv.Itoa(len(r.Data))
	} else {
		raw["modelName"] = loaded[0]
		raw["allModels"] = strings.Join(loaded, "|")
	}
	return p.OK(now, raw)
}
