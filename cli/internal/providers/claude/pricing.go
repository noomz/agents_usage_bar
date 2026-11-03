package claude

import (
	"encoding/json"
	"sort"
	"strings"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
)

type rate struct {
	InputPer1M      float64 `json:"inputPer1M"`
	OutputPer1M     float64 `json:"outputPer1M"`
	CacheWritePer1M float64 `json:"cacheWritePer1M"`
	CacheReadPer1M  float64 `json:"cacheReadPer1M"`
}

type pricing struct {
	Default rate            `json:"default"`
	Models  map[string]rate `json:"models"`
	// sortedKeys makes prefix and family picks deterministic. Swift walks a Dictionary here, so
	// an ID matching two keys can price differently between its runs.
	sortedKeys []string
}

// fallbackPricing is used only if the embedded table cannot be decoded.
var fallbackPricing = pricing{Default: rate{3, 15, 3.75, 0.30}, Models: map[string]rate{}}

func decodePricing(data []byte) pricing {
	var table pricing
	if err := json.Unmarshal(data, &table); err != nil || table.Models == nil {
		return fallbackPricing
	}
	table.sortedKeys = make([]string, 0, len(table.Models))
	for key := range table.Models {
		table.sortedKeys = append(table.sortedKeys, key)
	}
	sort.Strings(table.sortedKeys)
	return table
}

// rateFor cascades: exact, then prefix either way, then the priciest member of the named family,
// then the file default.
func (p pricing) rateFor(model *string) rate {
	if model == nil || *model == "" {
		return p.Default
	}
	if found, ok := p.Models[*model]; ok {
		return found
	}
	for _, key := range p.sortedKeys {
		if strings.HasPrefix(*model, key) || strings.HasPrefix(key, *model) {
			return p.Models[key]
		}
	}
	lower := strings.ToLower(*model)
	for _, family := range []string{"opus", "sonnet", "haiku"} {
		if !strings.Contains(lower, family) {
			continue
		}
		var best *rate
		for _, key := range p.sortedKeys {
			if strings.Contains(strings.ToLower(key), family) {
				candidate := p.Models[key]
				if best == nil || candidate.InputPer1M > best.InputPer1M {
					best = &candidate
				}
			}
		}
		if best != nil {
			return *best
		}
	}
	return p.Default
}

func (p pricing) cost(r transcriptRecord) decimal.Decimal {
	price := p.rateFor(r.model)
	micro := float64(r.inputTokens)*price.InputPer1M + float64(r.outputTokens)*price.OutputPer1M +
		float64(r.cacheCreationTokens)*price.CacheWritePer1M + float64(r.cacheReadTokens)*price.CacheReadPer1M
	return decimal.FromFloat64(micro / 1_000_000.0)
}
