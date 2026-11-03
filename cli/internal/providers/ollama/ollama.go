// Package ollama reports the localhost Ollama runtime.
package ollama

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/httpclient"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
	"github.com/noomz/agents_usage_bar/cli/internal/providers/localrow"
)

const (
	psURL   = "http://localhost:11434/api/ps"
	tagsURL = "http://localhost:11434/api/tags"
)

type psResponse struct {
	Models []struct {
		Name     *string `json:"name"`
		SizeVram *int64  `json:"size_vram"`
	} `json:"models"`
}

type tagsResponse struct {
	Models []struct {
		Name *string `json:"name"`
	} `json:"models"`
}

// Provider probes running and installed models.
type Provider struct {
	*localrow.Row
	http httpclient.Client
}

// Build always registers: a stopped runtime is a row state, not an absence.
func Build(env provider.Env) provider.Provider {
	return newProvider(env.LocalhostHTTP)
}

func newProvider(http httpclient.Client) *Provider {
	return &Provider{Row: localrow.New(domain.Ollama, "Ollama", map[string]string{"source": "ollama"}), http: http}
}

func (r psResponse) validate() error {
	for _, m := range r.Models {
		if m.Name == nil {
			return domain.DecodeError{Err: errors.New("model without name")}
		}
	}
	return nil
}

func installedCount(r tagsResponse, err error) int {
	if err != nil {
		return 0
	}
	for _, m := range r.Models {
		if m.Name == nil {
			return 0
		}
	}
	return len(r.Models)
}

// Fetch implements provider.Provider.
func (p *Provider) Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	var ps psResponse
	var tags tagsResponse
	var psErr, tagsErr error
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); psErr = p.http.GetJSON(ctx, psURL, nil, nil, &ps) }()
	go func() { defer wg.Done(); tagsErr = p.http.GetJSON(ctx, tagsURL, nil, nil, &tags) }()
	wg.Wait()
	if psErr == nil {
		psErr = ps.validate()
	}
	if psErr != nil {
		return p.Failed(now, psErr)
	}

	raw := map[string]string{"modelCount": strconv.Itoa(len(ps.Models))}
	switch len(ps.Models) {
	case 0:
		raw["installedCount"] = strconv.Itoa(installedCount(tags, tagsErr))
	case 1:
		m := ps.Models[0]
		vram := int64(0)
		if m.SizeVram != nil {
			vram = *m.SizeVram
		}
		raw["modelName"] = *m.Name
		raw["vramBytes"] = strconv.FormatInt(vram, 10)
		raw["allModels"] = *m.Name
	default:
		names := make([]string, len(ps.Models))
		for i, m := range ps.Models {
			names[i] = *m.Name
		}
		raw["modelName"] = names[0]
		raw["allModels"] = strings.Join(names, "|")
	}
	return p.OK(now, raw)
}
