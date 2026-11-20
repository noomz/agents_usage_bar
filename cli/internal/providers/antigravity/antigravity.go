package antigravity

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/provider"
)

type Provider struct {
	executable string
	home       string
	timeout    time.Duration
}

func Build(env provider.Env) provider.Provider {
	home := env.Paths.Home
	if !filepath.IsAbs(home) || env.Getenv == nil || !hasLogin(home) {
		return nil
	}
	dirs := append(filepath.SplitList(env.Getenv("PATH")), filepath.Join(home, ".local", "bin"), "/opt/homebrew/bin", "/usr/local/bin")
	for _, dir := range dirs {
		if !filepath.IsAbs(dir) {
			continue
		}
		if path, err := exec.LookPath(filepath.Join(dir, "agy")); err == nil {
			return &Provider{path, home, 12 * time.Second}
		}
	}
	return nil
}

func hasLogin(home string) bool {
	info, err := os.Stat(filepath.Join(home, ".gemini", "antigravity-cli", "antigravity-oauth-token"))
	return err == nil && info.Mode().IsRegular()
}

func (*Provider) ID() domain.ProviderID { return domain.Antigravity }
func (*Provider) DisplayName() string   { return "Antigravity" }
func (*Provider) Capabilities() domain.Capabilities {
	return domain.Capabilities{HasQuota: true}
}

func (p *Provider) Fetch(ctx context.Context, now time.Time) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	snap := domain.UsageSnapshot{ProviderID: p.ID(), AsOf: now, Raw: map[string]string{}}
	if !hasLogin(p.home) {
		snap.Raw[domain.RawProviderStatus] = domain.StatusSentinelUnauth
		return snap, domain.Unauthenticated(), nil
	}

	ctx, cancel := context.WithTimeout(ctx, p.timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, p.executable, "--print", "/usage", "--output-format", "json", "--print-timeout", "8s")
	cmd.Dir = string(filepath.Separator)
	cmd.Env = append(cmd.Environ(), "HOME="+p.home)
	cmd.WaitDelay = time.Second
	data, err := cmd.Output()
	if ctx.Err() != nil {
		return fail(domain.ErrNetwork, "agy /usage interrupted")
	}
	if err != nil {
		return fail(domain.ErrUnknown, "Could not run agy /usage")
	}
	windows := quotaWindows(data)
	if len(windows) == 0 {
		return fail(domain.ErrDecode, "Invalid quota from agy /usage")
	}
	snap.QuotaWindows = windows
	for _, window := range windows {
		if q := window.AsQuota(); snap.Quota == nil || q.Used > snap.Quota.Used {
			snap.Quota = q
		}
	}
	return snap, domain.OK(now), nil
}

func fail(kind domain.ProviderErrorKind, message string) (domain.UsageSnapshot, domain.ProviderStatus, error) {
	err := domain.ProviderError{Kind: kind, Message: message}
	return domain.UsageSnapshot{}, domain.ProviderStatus{}, err
}

type usage struct {
	Status  string
	Command struct {
		Name string
		Data struct{ Groups []group }
	}
}

type group struct {
	Name    string
	Buckets []bucket
}

type bucket struct {
	Name      string
	Window    string
	Remaining *float64 `json:"remaining_fraction"`
	Reset     string   `json:"reset_time"`
}

func quotaWindows(data []byte) []domain.QuotaWindow {
	var response usage
	if json.Unmarshal(data, &response) != nil || response.Status != "SUCCESS" || response.Command.Name != "usage" {
		return nil
	}
	var windows []domain.QuotaWindow
	names := map[string]bool{}
	for _, group := range response.Command.Data.Groups {
		for _, bucket := range group.Buckets {
			if bucket.Remaining == nil || *bucket.Remaining < 0 || *bucket.Remaining > 1 {
				continue
			}
			label, seconds := bucket.Name, float64(0)
			switch bucket.Window {
			case "5h":
				label, seconds = "5h", 18_000
			case "weekly":
				label, seconds = "7d", 604_800
			}
			name := group.Name + " " + label
			if strings.TrimSpace(group.Name) == "" || strings.TrimSpace(label) == "" || names[name] {
				return nil
			}
			names[name] = true
			consumed := 1 - *bucket.Remaining
			window := domain.QuotaWindow{Name: name, Utilization: &consumed}
			if seconds > 0 {
				window.Duration = &seconds
			}
			if reset, err := time.Parse(time.RFC3339Nano, bucket.Reset); err == nil {
				window.ResetsAt = &reset
			}
			windows = append(windows, window)
		}
	}
	return windows
}
