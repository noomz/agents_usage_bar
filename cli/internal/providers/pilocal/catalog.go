package pilocal

import (
	"encoding/json"
	"net/url"
	"os"
	"strconv"
	"strings"
)

// Catalog is the set of Pi provider ids to count.
type Catalog map[string]bool

const llamaCpp = "llama.cpp"

var cloudIDs = map[string]bool{
	"anthropic": true, "openai": true, "openai-codex": true, "openrouter": true, "xai": true,
	"amazon-bedrock": true, "router": true, "google": true, "gemini": true,
}

// LoadCatalog unions the local provider ids of Pi models.json files. Missing or unreadable
// files add nothing, and llama.cpp is always local.
func LoadCatalog(paths []string) Catalog {
	names := Catalog{llamaCpp: true}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var file struct {
			Providers map[string]json.RawMessage `json:"providers"`
		}
		if json.Unmarshal(data, &file) != nil {
			continue
		}
		for id, raw := range file.Providers {
			var entry struct {
				BaseURL *string `json:"baseUrl"`
			}
			base := ""
			if json.Unmarshal(raw, &entry) == nil && entry.BaseURL != nil {
				base = *entry.BaseURL
			}
			if IsLocal(id, base) {
				names[id] = true
			}
		}
	}
	return names
}

// IsLocal: the cloud denylist wins even when baseURL looks local.
func IsLocal(id, baseURL string) bool {
	key := strings.ToLower(id)
	if cloudIDs[key] {
		return false
	}
	if key == llamaCpp {
		return true
	}
	parsed, err := url.Parse(baseURL)
	if err != nil || parsed.Hostname() == "" {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	if isLoopback(host) || isPrivateIPv4(host) || strings.HasPrefix(host, "fe80:") || strings.HasSuffix(host, ".local") {
		return true
	}
	return strings.ToLower(parsed.Scheme) == "http" && !strings.ContainsAny(host, ".:")
}

func isLoopback(host string) bool {
	if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" {
		return true
	}
	octets, ok := ipv4Octets(host)
	return ok && octets[0] == 127
}

func isPrivateIPv4(host string) bool {
	o, ok := ipv4Octets(host)
	if !ok {
		return false
	}
	return o[0] == 10 || (o[0] == 172 && o[1] >= 16 && o[1] <= 31) || (o[0] == 192 && o[1] == 168) || (o[0] == 169 && o[1] == 254)
}

func ipv4Octets(host string) ([4]int, bool) {
	var out [4]int
	parts := strings.Split(host, ".")
	if len(parts) != 4 {
		return out, false
	}
	for i, part := range parts {
		n, err := strconv.ParseUint(part, 10, 8)
		if err != nil {
			return out, false
		}
		out[i] = int(n)
	}
	return out, true
}
