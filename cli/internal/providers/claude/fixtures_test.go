package claude

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/cache"
	"github.com/noomz/agents_usage_bar/cli/internal/clock"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/secret"
)

const fixtures = "../../../../AgentsUsageBarTests/ProvidersClaudeTests/Fixtures/"

var testNow = time.Date(2026, 5, 13, 12, 0, 0, 0, time.UTC)

func testDayKeys() *domain.DayKeyOwner {
	return domain.NewDayKeyOwner(clock.Fixed(testNow), time.UTC)
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

func fixture(t *testing.T, name string) string {
	t.Helper()
	data, err := os.ReadFile(fixtures + name)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func assistantLine(stamp, request, model string, input, output, cacheWrite, cacheRead int) string {
	line := map[string]any{
		"type": "assistant", "timestamp": stamp,
		"message": map[string]any{"model": model, "role": "assistant", "usage": map[string]any{
			"input_tokens": input, "output_tokens": output, "cache_creation_input_tokens": cacheWrite, "cache_read_input_tokens": cacheRead,
		}},
	}
	if request != "" {
		line["requestId"] = request
	}
	data, _ := json.Marshal(line)
	return string(data) + "\n"
}

type httpCall struct {
	method, url string
	bearer      string
	headers     map[string]string
	body        any
}

// scriptedHTTP answers GET and POST in order: a string is a body, an error is returned.
type scriptedHTTP struct {
	mu    sync.Mutex
	gets  []any
	posts []any
	calls []httpCall
}

func (s *scriptedHTTP) respond(queue *[]any, out any) error {
	if len(*queue) == 0 {
		return fmt.Errorf("unexpected request")
	}
	next := (*queue)[0]
	*queue = (*queue)[1:]
	switch a := next.(type) {
	case error:
		return a
	case string:
		if err := json.Unmarshal([]byte(a), out); err != nil {
			return domain.DecodeError{Err: err}
		}
	}
	return nil
}

func (s *scriptedHTTP) GetJSON(_ context.Context, rawURL string, bearer *secret.Secret, headers map[string]string, out any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, httpCall{"GET", rawURL, bearer.Reveal(), headers, nil})
	return s.respond(&s.gets, out)
}

func (s *scriptedHTTP) PostJSON(_ context.Context, rawURL string, body any, _ *secret.Secret, headers map[string]string, out any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, httpCall{"POST", rawURL, "", headers, body})
	return s.respond(&s.posts, out)
}

func (s *scriptedHTTP) PostForm(context.Context, string, [][2]string, map[string]string, any) error {
	return errors.New("unexpected form post")
}

// memoryStore persists cursors and totals across fetches, like the file store.
type memoryStore struct {
	cache.Noop
	offsets map[string]domain.TranscriptOffset
	daily   map[domain.ProviderID]domain.DailyUsageRecord
}

func newMemoryStore() *memoryStore {
	return &memoryStore{offsets: map[string]domain.TranscriptOffset{}, daily: map[domain.ProviderID]domain.DailyUsageRecord{}}
}

func (m *memoryStore) AllTranscriptOffsets() map[string]domain.TranscriptOffset { return m.offsets }
func (m *memoryStore) SetTranscriptOffsets(o []domain.TranscriptOffset) {
	for _, offset := range o {
		m.offsets[offset.URL] = offset
	}
}

type fakeUsage struct {
	response *usageResponse
	err      error
}

func (f fakeUsage) getUsage(context.Context) (*usageResponse, error) { return f.response, f.err }

func newReads(roots []string, oauth usageSource, store cache.Store) *sessionReads {
	return &sessionReads{
		roots:   func() []string { return roots },
		pricing: decodePricing([]byte(`{"default":{"inputPer1M":2,"outputPer1M":10,"cacheWritePer1M":2.5,"cacheReadPer1M":0.2},"models":{"claude-test":{"inputPer1M":1,"outputPer1M":5,"cacheWritePer1M":1.25,"cacheReadPer1M":0.1}}}`)),
		oauth:   oauth, cache: store, dayKeys: testDayKeys(), status: notYetFetched,
	}
}
