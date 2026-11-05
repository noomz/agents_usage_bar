package claude

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestDiscoverHookTargetsListsDefaultThenSortedInstances(t *testing.T) {
	home := t.TempDir()
	instances := filepath.Join(home, ".ccs", "instances")
	writeFile(t, filepath.Join(instances, "work", "settings.json"), `{}`)
	if err := os.MkdirAll(filepath.Join(instances, "personal"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(instances, ".hidden"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeFile(t, filepath.Join(instances, "strayfile"), "")

	want := []HookTarget{
		{"default", []string{"default"}, filepath.Join(home, ".claude", "settings.json")},
		{"personal", []string{"personal"}, filepath.Join(instances, "personal", "settings.json")},
		{"work", []string{"work"}, filepath.Join(instances, "work", "settings.json")},
	}
	if got := DiscoverHookTargets(home); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
}

func TestDiscoverHookTargetsWithoutInstancesIsDefaultOnly(t *testing.T) {
	got := DiscoverHookTargets(t.TempDir())
	if len(got) != 1 || got[0].Slug != "default" {
		t.Fatalf("got %+v", got)
	}
}

func TestDiscoverHookTargetsFoldsSharedSettings(t *testing.T) {
	home := t.TempDir()
	shared := filepath.Join(home, ".ccs", "shared", "settings.json")
	writeFile(t, shared, `{}`)
	for _, slug := range []string{"personal", "work"} {
		dir := filepath.Join(home, ".ccs", "instances", slug)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(shared, filepath.Join(dir, "settings.json")); err != nil {
			t.Fatal(err)
		}
	}

	got := DiscoverHookTargets(home)
	if len(got) != 2 || got[0].Slug != "default" {
		t.Fatalf("got %+v", got)
	}
	if got[1].Slug != "personal" || !reflect.DeepEqual(got[1].Accounts, []string{"personal", "work"}) {
		t.Fatalf("folded target %+v", got[1])
	}
}

func TestDiscoverHookTargetsFoldsIntoDefaultWhenItShares(t *testing.T) {
	home := t.TempDir()
	settings := filepath.Join(home, ".claude", "settings.json")
	writeFile(t, settings, `{}`)
	dir := filepath.Join(home, ".ccs", "instances", "work")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(settings, filepath.Join(dir, "settings.json")); err != nil {
		t.Fatal(err)
	}

	got := DiscoverHookTargets(home)
	if len(got) != 1 || got[0].Slug != "default" || !reflect.DeepEqual(got[0].Accounts, []string{"default", "work"}) {
		t.Fatalf("got %+v", got)
	}
}

func TestHookFeedAccountsAttributesLikeFetchAndDeletesNothing(t *testing.T) {
	feedDir := t.TempDir()
	sessions := hookSessionsDir(feedDir)
	old := time.Now().Add(-72 * time.Hour)
	recent := time.Now().Add(-time.Minute).Truncate(time.Second)
	expired := writeSession(t, filepath.Join(sessions, "work"), "s-old", costJSON("s-old", 1), old)
	writeSession(t, filepath.Join(sessions, "default"), "s-work",
		`{"session_id":"s-work","transcript_path":"/h/.ccs/instances/work/projects/p/s.jsonl"}`, recent)
	writeSession(t, sessions, "s-top", costJSON("s-top", 1), recent)
	writeSession(t, filepath.Join(sessions, "broken"), "s-bad", `{not json`, recent)

	got := HookFeedAccounts(feedDir)
	if len(got) != 2 || got[0].Name != "default" || got[1].Name != "work" {
		t.Fatalf("got %+v", got)
	}
	if !got[1].Newest.Equal(recent) {
		t.Fatalf("work newest %v, want %v", got[1].Newest, recent)
	}
	if _, err := os.Stat(expired); err != nil {
		t.Fatalf("status path must not delete feed files: %v", err)
	}
}

func TestHookFeedAccountsWithoutFeedIsEmpty(t *testing.T) {
	if got := HookFeedAccounts(filepath.Join(t.TempDir(), "absent")); len(got) != 0 {
		t.Fatalf("got %+v", got)
	}
}
