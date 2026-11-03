package codex

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"

	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

// credentials is what ~/.codex/auth.json resolves to.
type credentials struct {
	token     secret.Secret
	accountID *string
	// subscription is false for a top-level OPENAI_API_KEY, which is never a login.
	subscription bool
}

// loadCredentials returns nil when the file is absent, malformed, or holds no bearer.
func loadCredentials(path string) *credentials {
	var top map[string]any
	if !readJSON(path, &top) {
		return nil
	}
	if key, _ := top["OPENAI_API_KEY"].(string); key != "" {
		return &credentials{token: secret.New(key)}
	}
	tokens, _ := top["tokens"].(map[string]any)
	access, _ := tokens["access_token"].(string)
	if access == "" {
		return nil
	}
	return &credentials{token: secret.New(access), accountID: stringField(tokens, "account_id"), subscription: true}
}

func readJSON(path string, out any) bool {
	data, err := os.ReadFile(path)
	return err == nil && json.Unmarshal(data, out) == nil
}

func stringField(m map[string]any, key string) *string {
	if s, ok := m[key].(string); ok {
		return &s
	}
	return nil
}

func nonEmptyField(m map[string]any, key string) *string {
	if s := stringField(m, key); s != nil && *s != "" {
		return s
	}
	return nil
}

// login is one enabled ChatGPT subscription login found on disk.
type login struct {
	accountID *string
	token     secret.Secret
	email     *string
	// planSuffix is the lowercased last `-` segment of a CLIProxy filename.
	planSuffix *string
	cliproxy   bool
}

var planSlugs = map[string]bool{
	"plus": true, "pro": true, "team": true, "business": true,
	"enterprise": true, "edu": true, "free": true, "guest": true,
}

// discover reads `codex-*.json` in dir, then the optional Codex CLI auth file.
func discover(dir, authPath string) []login {
	var logins []login
	seen := map[string]bool{}
	entries, _ := os.ReadDir(dir)
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "codex-") || !strings.HasSuffix(name, ".json") {
			continue
		}
		l := parseCLIProxy(filepath.Join(dir, name), name)
		if l == nil || seen[*l.accountID] {
			continue
		}
		seen[*l.accountID] = true
		logins = append(logins, *l)
	}

	auth := loadCredentials(authPath)
	if auth == nil || !auth.subscription {
		return logins
	}
	if auth.accountID != nil && *auth.accountID != "" {
		if !seen[*auth.accountID] {
			logins = append(logins, login{accountID: auth.accountID, token: auth.token})
		}
		return logins
	}
	if len(logins) == 0 {
		logins = append(logins, login{token: auth.token})
	}
	return logins
}

func parseCLIProxy(path, filename string) *login {
	var top map[string]any
	if !readJSON(path, &top) || truthy(top["disabled"]) {
		return nil
	}
	if kind, present := top["type"]; present && kind != "codex" {
		return nil
	}
	token, accountID := nonEmptyField(top, "access_token"), nonEmptyField(top, "account_id")
	if token == nil || accountID == nil {
		return nil
	}
	return &login{
		accountID:  accountID,
		token:      secret.New(*token),
		email:      nonEmptyField(top, "email"),
		planSuffix: filenamePlanSuffix(filename),
		cliproxy:   true,
	}
}

// truthy matches Swift's `as? Bool == true`, which bridges the JSON number 1 to true.
func truthy(v any) bool {
	return v == true || v == float64(1)
}

func filenamePlanSuffix(filename string) *string {
	segments := strings.FieldsFunc(strings.TrimSuffix(filename, ".json"), func(r rune) bool { return r == '-' })
	if len(segments) == 0 {
		return nil
	}
	last := strings.ToLower(segments[len(segments)-1])
	return &last
}

func equal(p *string, s string) bool { return p != nil && *p == s }

func nonEmptyPlan(planTypes map[string]string, l login) string {
	key := ""
	if l.accountID != nil {
		key = *l.accountID
	}
	return strings.ToLower(planTypes[key])
}

// candidates lists a login's possible labels, best first.
func candidates(l login, logins []login, planTypes map[string]string) []string {
	var options []string
	if l.cliproxy {
		if l.planSuffix != nil && planSlugs[*l.planSuffix] {
			count := 0
			for _, o := range logins {
				if o.cliproxy && equal(o.planSuffix, *l.planSuffix) {
					count++
				}
			}
			if count == 1 {
				options = append(options, *l.planSuffix)
			}
		}
		if l.email != nil {
			count := 0
			for _, o := range logins {
				if equal(o.email, *l.email) {
					count++
				}
			}
			if count == 1 {
				options = append(options, *l.email)
			}
		}
	} else if plan := nonEmptyPlan(planTypes, l); plan != "" {
		claimers := 0
		for _, o := range logins {
			if equal(o.planSuffix, plan) || (!o.cliproxy && nonEmptyPlan(planTypes, o) == plan) {
				claimers++
			}
		}
		if claimers == 1 {
			options = append(options, plan)
		}
	}
	if l.accountID != nil && *l.accountID != "" {
		id := *l.accountID
		if utf8.RuneCountInString(id) > 8 {
			options = append(options, "acct-"+string([]rune(id)[:8]), "acct-"+id)
		} else {
			options = append(options, "acct-"+id)
		}
	}
	return options
}

func labelAt(options []string, index int) string {
	if index < len(options) {
		return options[index]
	}
	if len(options) > 0 {
		return options[len(options)-1]
	}
	return "codex"
}

// labeledLogin pairs a login's position in discover's result with its unique display label.
type labeledLogin struct {
	index int
	label string
}

// labeled assigns each login a unique label, sorted by label. planTypes maps account id to the
// wham/usage plan_type; a login with no account id reads planTypes[""].
func labeled(logins []login, planTypes map[string]string) []labeledLogin {
	options := make([][]string, len(logins))
	limit := 1
	for i, l := range logins {
		options[i] = candidates(l, logins, planTypes)
		limit = max(limit, len(options[i])+1)
	}
	position := make([]int, len(logins))
	for range limit {
		buckets := map[string][]int{}
		for i := range logins {
			label := labelAt(options[i], position[i])
			buckets[label] = append(buckets[label], i)
		}
		moved := false
		for _, members := range buckets {
			if len(members) < 2 {
				continue
			}
			for _, i := range members {
				if position[i]+1 < len(options[i]) {
					position[i]++
					moved = true
				}
			}
		}
		if !moved {
			break
		}
	}
	out := make([]labeledLogin, len(logins))
	for i := range logins {
		out[i] = labeledLogin{index: i, label: labelAt(options[i], position[i])}
	}
	sort.SliceStable(out, func(a, b int) bool { return out[a].label < out[b].label })
	return out
}
