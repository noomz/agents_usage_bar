package codex

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const fixtures = "../../../../AgentsUsageBarTests/ProvidersCodexTests/Fixtures/"

func proxyFile(accountID, token, email, extra string) string {
	return fmt.Sprintf(`{%s"access_token":%q,"account_id":%q,"email":%q}`, extra, token, accountID, email)
}

func authFile(accountID *string, token string) string {
	if accountID == nil {
		return fmt.Sprintf(`{"OPENAI_API_KEY":null,"tokens":{"access_token":%q}}`, token)
	}
	return fmt.Sprintf(`{"OPENAI_API_KEY":null,"tokens":{"access_token":%q,"account_id":%q}}`, token, *accountID)
}

func writeAll(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, contents := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
}

func ptr(s string) *string { return &s }

func TestDiscoverAndLabel(t *testing.T) {
	const a, b, c = "aaaaaaaa-1111", "bbbbbbbb-2222", "cccccccc-3333"
	cases := []struct {
		name      string
		files     map[string]string
		auth      string
		planTypes map[string]string
		labels    []string
	}{
		{name: "missing everything", labels: []string{}},
		{
			name: "unique plan slugs are lowercased and sorted",
			files: map[string]string{
				"codex-bbbbbbbb-b@example.com-TEAM.json": proxyFile(b, "t2", "b@example.com", ""),
				"codex-aaaaaaaa-a@example.com-Plus.json": proxyFile(a, "t1", "a@example.com", `"priority":1,"expired":"2099-01-01",`),
			},
			labels: []string{"plus", "team"},
		},
		{
			name: "duplicate slug uses unique emails in code unit order",
			files: map[string]string{
				"codex-aaaaaaaa-zoo@example.com-plus.json":   proxyFile(a, "t1", "zoo@example.com", ""),
				"codex-bbbbbbbb-Alpha@example.com-plus.json": proxyFile(b, "t2", "Alpha@example.com", ""),
			},
			labels: []string{"Alpha@example.com", "zoo@example.com"},
		},
		{
			name: "duplicate email and shared prefix reach the full id",
			files: map[string]string{
				"codex-aaaaaaaa-a@example.com-plus.json": proxyFile(a, "t1", "same@example.com", ""),
				"codex-bbbbbbbb-b@example.com-plus.json": proxyFile("aaaaaaaa-2222", "t2", "same@example.com", ""),
				"codex-cccccccc-c@example.com-team.json": proxyFile(c, "t3", "", ""),
			},
			labels: []string{"acct-aaaaaaaa-1111", "acct-aaaaaaaa-2222", "team"},
		},
		{
			name: "email matching another slug falls forward",
			files: map[string]string{
				"codex-aaaaaaaa-a@example.com-plus.json":   proxyFile(a, "t1", "a@example.com", ""),
				"codex-bbbbbbbb-b@example.com-custom.json": proxyFile(b, "t2", "plus", ""),
			},
			labels: []string{"a@example.com", "acct-bbbbbbbb"},
		},
		{
			name: "skipped files do not drop a valid sibling",
			files: map[string]string{
				"codex-00000000-bad@example.com-plus.json":         "{",
				"codex-11111111-off@example.com-pro.json":          proxyFile("11111111-1111", "t", "off@example.com", `"disabled":true,`),
				"codex-11111112-off@example.com-pro.json":          proxyFile("11111112-1111", "t", "off2@example.com", `"disabled":1,`),
				"codex-22222222-other@example.com-team.json":       proxyFile("22222222-2222", "t", "other@example.com", `"type":"openai",`),
				"codex-22222223-null@example.com-team.json":        proxyFile("22222223-2222", "t", "null@example.com", `"type":null,`),
				"codex-22222224-num@example.com-team.json":         proxyFile("22222224-2222", "t", "num@example.com", `"type":3,`),
				"codex-33333333-empty-token@example.com-plus.json": proxyFile("33333333-3333", "", "empty-token@example.com", ""),
				"codex-44444444-empty-id@example.com-plus.json":    proxyFile("", "t", "empty-id@example.com", ""),
				"notes.json": "notes",
				"codex-55555555-kept@example.com-edu.json": proxyFile("55555555-5555", "t", "kept@example.com", ""),
			},
			labels: []string{"edu"},
		},
		{
			name: "duplicate account keeps the smaller filename",
			files: map[string]string{
				"codex-bbbbbbbb-b@example.com-team.json": proxyFile("same", "t2", "b@example.com", ""),
				"codex-aaaaaaaa-a@example.com-plus.json": proxyFile("same", "t1", "a@example.com", ""),
			},
			labels: []string{"plus"},
		},
		{
			name:   "api key auth is never a login",
			auth:   `{"OPENAI_API_KEY":"k","tokens":{"access_token":"t","account_id":"d"}}`,
			labels: []string{},
		},
		{
			name:   "auth omitted when its account is already in CLIProxy",
			files:  map[string]string{"codex-aaaaaaaa-a@example.com-plus.json": proxyFile(a, "t1", "a@example.com", "")},
			auth:   authFile(ptr(a), "t2"),
			labels: []string{"plus"},
		},
		{
			name:      "auth joins and uses plan_type",
			files:     map[string]string{"codex-aaaaaaaa-a@example.com-team.json": proxyFile(a, "t1", "a@example.com", "")},
			auth:      authFile(ptr(b), "t2"),
			planTypes: map[string]string{b: "Pro"},
			labels:    []string{"pro", "team"},
		},
		{
			name:      "auth plan_type matching a slug falls to the prefix",
			files:     map[string]string{"codex-aaaaaaaa-a@example.com-plus.json": proxyFile(a, "t1", "a@example.com", "")},
			auth:      authFile(ptr(b), "t2"),
			planTypes: map[string]string{b: "plus"},
			labels:    []string{"acct-bbbbbbbb", "plus"},
		},
		{
			name:      "subscription without account id is a login when alone",
			auth:      authFile(nil, "t"),
			planTypes: map[string]string{"": "Free"},
			labels:    []string{"free"},
		},
		{
			name:   "subscription without account id is dropped beside CLIProxy",
			files:  map[string]string{"codex-aaaaaaaa-a@example.com-plus.json": proxyFile(a, "t1", "a@example.com", "")},
			auth:   authFile(nil, "t"),
			labels: []string{"plus"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			proxy := filepath.Join(dir, "proxy")
			auth := filepath.Join(dir, "auth.json")
			if tc.files != nil {
				writeAll(t, proxy, tc.files)
			}
			if tc.auth != "" {
				writeAll(t, dir, map[string]string{"auth.json": tc.auth})
			}
			got := []string{}
			for _, item := range labeled(discover(proxy, auth), tc.planTypes) {
				got = append(got, item.label)
			}
			if !reflect.DeepEqual(got, tc.labels) {
				t.Fatalf("labels = %v, want %v", got, tc.labels)
			}
		})
	}
}

func TestDiscoverKeepsSmallerFilenameTokenAndRedactsIt(t *testing.T) {
	dir := t.TempDir()
	writeAll(t, dir, map[string]string{
		"codex-bbbbbbbb-b@example.com-team.json": proxyFile("same", "test-token-team", "b@example.com", ""),
		"codex-aaaaaaaa-a@example.com-plus.json": proxyFile("same", "test-token-plus", "a@example.com", ""),
	})
	logins := discover(dir, filepath.Join(dir, "auth.json"))
	if len(logins) != 1 || logins[0].token.Reveal() != "test-token-plus" {
		t.Fatalf("wrong login kept: %d", len(logins))
	}
	if rendered := fmt.Sprintf("%+v %#v", logins, logins); strings.Contains(rendered, "test-token") {
		t.Fatalf("token leaked through formatting")
	}
}

func TestLoadCredentials(t *testing.T) {
	cases := []struct {
		name         string
		fixture      string
		contents     string
		want         string
		accountID    *string
		subscription bool
	}{
		{name: "missing file"},
		{name: "subscription fixture", fixture: "codex-auth-subscription.json", want: "subscription", subscription: true},
		{name: "api key wins", fixture: "codex-auth-apikey.json", want: "FAKE-api-key-xyz-direct-bearer-aaaa"},
		{name: "empty tokens", fixture: "codex-auth-empty.json"},
		{name: "malformed", contents: "{not json"},
		{name: "empty api key falls through", contents: `{"OPENAI_API_KEY":"","tokens":{"access_token":"tok","account_id":"acc"}}`, want: "tok", accountID: ptr("acc"), subscription: true},
		{name: "account id absent", contents: `{"tokens":{"access_token":"tok"}}`, want: "tok", subscription: true},
		{name: "neither path", contents: `{"last_refresh":"2026-05-13T11:47:21Z"}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "auth.json")
			switch {
			case tc.fixture != "":
				path = fixtures + tc.fixture
			case tc.contents != "":
				if err := os.WriteFile(path, []byte(tc.contents), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			got := loadCredentials(path)
			if tc.want == "" {
				if got != nil {
					t.Fatalf("expected no credentials")
				}
				return
			}
			if got == nil {
				t.Fatalf("expected credentials")
			}
			if got.subscription != tc.subscription {
				t.Fatalf("subscription = %v", got.subscription)
			}
			if tc.want != "subscription" && got.token.Reveal() != tc.want {
				t.Fatalf("wrong token resolved")
			}
			if tc.fixture == "" && !reflect.DeepEqual(got.accountID, tc.accountID) {
				t.Fatalf("accountID = %v", got.accountID)
			}
		})
	}
}
