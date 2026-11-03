package resources

import (
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
)

func TestEmbeddedCopiesMatchTheAppResources(t *testing.T) {
	const appResources = "../../../AgentsUsageBar/Resources"
	cases := []struct {
		source   string
		embedded []byte
	}{
		{"Pricing/claude-models.json", ClaudePricing},
		{"Pricing/codex-models.json", CodexPricing},
		{"Onboarding/providers.json", Providers},
	}
	for _, c := range cases {
		t.Run(c.source, func(t *testing.T) {
			if !json.Valid(c.embedded) || len(c.embedded) == 0 {
				t.Error("embedded copy is not JSON")
			}
			original, err := os.ReadFile(filepath.Join(appResources, c.source))
			if errors.Is(err, fs.ErrNotExist) {
				t.Skip("no app resources here, as in a module download")
			}
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(original, c.embedded) {
				t.Errorf("cli/internal/resources copy differs from AgentsUsageBar/Resources/%s; copy the file over", c.source)
			}
		})
	}
}
