// Package cache reads and updates the live cache file the app writes (today.json).
//
// `LoadAll` only reads. Providers call the offset, baseline, and daily-usage methods, exactly
// as the Swift providers write through FileCacheStore during `aub --live`. Those writes keep
// the stored provider rows byte-for-byte, so a Go process never rewrites what the app owns.
package cache

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/swiftjson"
)

// Store is the cache seam providers and the usage session see.
type Store interface {
	// LoadAll returns every persisted provider row. A missing or unreadable cache is empty.
	LoadAll() map[domain.ProviderID]domain.ProviderState
	// Baseline returns the stored baseline for id, nil when none exists.
	Baseline(id domain.ProviderID) *domain.BaselineRecord
	// MaintainBaseline sets a fresh baseline on a new day or a negative delta; otherwise it
	// keeps the baseline and updates LastValue. Never call it inside WithCursors: it takes the
	// same lock.
	MaintainBaseline(id domain.ProviderID, now time.Time, currentValue float64)
	// WithCursors runs body holding the cross-process cursor lock. Cursors are reachable only
	// here, so reading them and adding the delta they measure happen under one lock. A second
	// process in between would count the same bytes, and the total would stay doubled until
	// midnight. Body must make no network call.
	WithCursors(body func(Cursors))
}

// Cursors is the cursor and daily-total state, valid only inside WithCursors.
type Cursors interface {
	// AllTranscriptOffsets returns every cursor.
	AllTranscriptOffsets() map[string]domain.TranscriptOffset
	// SetTranscriptOffsets upserts cursors keyed by URL in one write.
	SetTranscriptOffsets(offsets []domain.TranscriptOffset)
	// AccumulateDailyUsage adds a poll's delta to id's running total and returns the new
	// total. A new day key restarts the total from the delta.
	AccumulateDailyUsage(id domain.ProviderID, now time.Time, deltaTokens int, deltaCostUSD decimal.Decimal, deltaSessionTokens map[string]int) domain.DailyUsageRecord
}

// File is the production Store, one JSON file written atomically by rename.
type File struct {
	path    string
	dayKeys *domain.DayKeyOwner
	mu      sync.Mutex
}

// NewFile opens a cache path. Nothing is created until a provider writes.
func NewFile(path string, dayKeys *domain.DayKeyOwner) *File {
	return &File{path: path, dayKeys: dayKeys}
}

const currentSchema = 3

// lock takes the advisory lock on today.json.lock, shared by every process and goroutine that
// writes the store. The kernel drops it if the process dies. The app's FileCacheStore does not
// take it yet. If the lock file cannot be opened the store's directory is not writable either,
// so nothing persists and running unlocked cannot double a total.
func (f *File) lock() (unlock func()) {
	if err := os.MkdirAll(filepath.Dir(f.path), 0o755); err != nil {
		return func() {}
	}
	file, err := os.OpenFile(f.path+".lock", os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		return func() {}
	}
	for {
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX)
		if !errors.Is(err, syscall.EINTR) {
			break
		}
	}
	return func() { file.Close() }
}

// WithCursors implements Store.
func (f *File) WithCursors(body func(Cursors)) {
	defer f.lock()()
	body(fileCursors{f})
}

// fileCursors is File's Cursors, handed out only under the lock.
type fileCursors struct{ f *File }

// envelope keeps sections raw so a run that only needs one section does not decode 1 MB of
// transcript cursors, and a write leaves `providers` exactly as the app wrote it.
type envelope struct {
	providers   json.RawMessage
	baselines   json.RawMessage
	transcripts json.RawMessage
	dailyUsage  json.RawMessage
}

// load returns ok=false for a file that exists but cannot be used: corrupt, unreadable, or from a
// newer schema. Such a file is never written, because a newer app owns its contents. A missing
// file is an empty, writable envelope.
func (f *File) load() (e *envelope, ok bool) {
	data, err := os.ReadFile(f.path)
	if errors.Is(err, os.ErrNotExist) {
		return &envelope{}, true
	}
	if err != nil {
		return nil, false
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil {
		return nil, false
	}
	var schema int
	if err := json.Unmarshal(top["schemaVersion"], &schema); err != nil {
		return nil, false
	}
	// Later schemas add sections, so each version requires what it had when written.
	required := map[int][]string{
		1: {"providers", "baselines"},
		2: {"providers", "baselines", "transcripts"},
		3: {"providers", "baselines", "transcripts", "dailyUsage"},
	}[schema]
	if required == nil {
		return nil, false
	}
	for _, key := range required {
		if _, ok := top[key]; !ok {
			return nil, false
		}
	}
	return &envelope{providers: top["providers"], baselines: top["baselines"], transcripts: top["transcripts"], dailyUsage: top["dailyUsage"]}, true
}

func (f *File) write(e *envelope) {
	object := map[string]any{
		"schemaVersion": currentSchema,
		"providers":     rawOr(e.providers, "[]"),
		"baselines":     rawOr(e.baselines, "[]"),
		"transcripts":   rawOr(e.transcripts, "{}"),
		"dailyUsage":    rawOr(e.dailyUsage, "[]"),
	}
	data := []byte(swiftjson.Encode(object, swiftjson.Options{}))
	if err := os.MkdirAll(filepath.Dir(f.path), 0o755); err != nil {
		return
	}
	tmp, err := os.CreateTemp(filepath.Dir(f.path), ".today-*.json")
	if err != nil {
		return
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return
	}
	if err := tmp.Close(); err != nil {
		return
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return
	}
	_ = os.Rename(tmp.Name(), f.path)
}

func rawOr(raw json.RawMessage, fallback string) swiftjson.Raw {
	if len(raw) == 0 {
		return swiftjson.Raw(fallback)
	}
	return swiftjson.Raw(raw)
}

// pairs walks Swift's encoding of a dictionary with a non-String key: [key, value, key, value].
func pairs(raw json.RawMessage, visit func(key string, value any) error) error {
	if len(raw) == 0 {
		return nil
	}
	tree, err := domain.ParseJSON(raw)
	if err != nil {
		return err
	}
	items, ok := tree.([]any)
	if !ok || len(items)%2 != 0 {
		return errors.New("expected key-value pairs")
	}
	for i := 0; i < len(items); i += 2 {
		key, ok := items[i].(string)
		if !ok {
			return errors.New("expected string key")
		}
		if err := visit(key, items[i+1]); err != nil {
			return err
		}
	}
	return nil
}

// LoadAll implements Store.
func (f *File) LoadAll() map[domain.ProviderID]domain.ProviderState {
	f.mu.Lock()
	e, ok := f.load()
	f.mu.Unlock()
	states := map[domain.ProviderID]domain.ProviderState{}
	if !ok {
		return states
	}
	err := pairs(e.providers, func(key string, value any) error {
		state, err := domain.DecodeProviderState(value)
		if err != nil {
			return err
		}
		states[domain.ProviderID(key)] = state
		return nil
	})
	if err != nil {
		return map[domain.ProviderID]domain.ProviderState{}
	}
	return states
}

func decodeBaselines(raw json.RawMessage) map[string]domain.BaselineRecord {
	out := map[string]domain.BaselineRecord{}
	_ = pairs(raw, func(key string, value any) error {
		rec, err := domain.DecodeBaseline(value)
		if err != nil {
			return err
		}
		out[key] = rec
		return nil
	})
	return out
}

// pairsOf re-encodes a dictionary in Swift's [key, value, ...] form with sorted keys.
func pairsOf[V any](m map[string]V, encode func(V) any) swiftjson.Raw {
	items := make([]any, 0, len(m)*2)
	for _, k := range domain.SortedKeys(m) {
		items = append(items, k, encode(m[k]))
	}
	return swiftjson.Raw(swiftjson.Encode(items, swiftjson.Options{}))
}

func baselineTree(b domain.BaselineRecord) any {
	return map[string]any{
		"value": b.Value, "date": b.Date, "lastValue": b.LastValue, "lastUpdated": domain.RefSeconds(b.LastUpdated),
	}
}

// Baseline implements Store.
func (f *File) Baseline(id domain.ProviderID) *domain.BaselineRecord {
	f.mu.Lock()
	defer f.mu.Unlock()
	e, ok := f.load()
	if !ok {
		return nil
	}
	if rec, ok := decodeBaselines(e.baselines)[string(id)]; ok {
		return &rec
	}
	return nil
}

// MaintainBaseline implements Store.
func (f *File) MaintainBaseline(id domain.ProviderID, now time.Time, currentValue float64) {
	defer f.lock()()
	f.mu.Lock()
	defer f.mu.Unlock()
	e, ok := f.load()
	if !ok {
		return
	}
	baselines := decodeBaselines(e.baselines)
	today := f.dayKeys.KeyFor(now)
	existing, ok := baselines[string(id)]
	base := currentValue
	if ok && existing.Date == today && currentValue >= existing.Value {
		base = existing.Value
	}
	baselines[string(id)] = domain.BaselineRecord{Value: base, Date: today, LastValue: currentValue, LastUpdated: now}
	e.baselines = json.RawMessage(pairsOf(baselines, baselineTree))
	f.write(e)
}

func decodeOffsets(raw json.RawMessage) map[string]domain.TranscriptOffset {
	out := map[string]domain.TranscriptOffset{}
	if len(raw) == 0 {
		return out
	}
	tree, err := domain.ParseJSON(raw)
	if err != nil {
		return out
	}
	m, ok := tree.(map[string]any)
	if !ok {
		return out
	}
	for key, value := range m {
		offset, err := domain.DecodeTranscriptOffset(value)
		if err != nil {
			return map[string]domain.TranscriptOffset{}
		}
		out[key] = offset
	}
	return out
}

// AllTranscriptOffsets implements Cursors.
func (c fileCursors) AllTranscriptOffsets() map[string]domain.TranscriptOffset {
	f := c.f
	f.mu.Lock()
	defer f.mu.Unlock()
	e, ok := f.load()
	if !ok {
		return map[string]domain.TranscriptOffset{}
	}
	return decodeOffsets(e.transcripts)
}

// SetTranscriptOffsets implements Cursors.
func (c fileCursors) SetTranscriptOffsets(offsets []domain.TranscriptOffset) {
	if len(offsets) == 0 {
		return
	}
	f := c.f
	f.mu.Lock()
	defer f.mu.Unlock()
	e, ok := f.load()
	if !ok {
		return
	}
	all := decodeOffsets(e.transcripts)
	for _, o := range offsets {
		all[o.URL] = o
	}
	tree := make(map[string]any, len(all))
	for k, o := range all {
		tree[k] = map[string]any{"url": o.URL, "byteOffset": o.ByteOffset, "lastModified": domain.RefSeconds(o.LastModified)}
	}
	e.transcripts = json.RawMessage(swiftjson.Encode(tree, swiftjson.Options{}))
	f.write(e)
}

func dailyTree(d domain.DailyUsageRecord) any {
	sessions := make(map[string]any, len(d.SessionTokens))
	for k, v := range d.SessionTokens {
		sessions[k] = v
	}
	return map[string]any{
		"date": d.Date, "tokens": d.Tokens, "costUSD": swiftjson.Raw(d.CostUSD.String()), "sessionTokens": sessions,
	}
}

// AccumulateDailyUsage implements Cursors.
func (c fileCursors) AccumulateDailyUsage(id domain.ProviderID, now time.Time, deltaTokens int, deltaCostUSD decimal.Decimal, deltaSessionTokens map[string]int) domain.DailyUsageRecord {
	f := c.f
	f.mu.Lock()
	defer f.mu.Unlock()
	today := f.dayKeys.KeyFor(now)
	next := domain.DailyUsageRecord{Date: today, Tokens: deltaTokens, CostUSD: deltaCostUSD, SessionTokens: map[string]int{}}
	for k, v := range deltaSessionTokens {
		next.SessionTokens[k] = v
	}
	// With no readable cursors the delta is the whole day, so it is already the total.
	e, ok := f.load()
	if !ok {
		return next
	}
	records := map[string]domain.DailyUsageRecord{}
	_ = pairs(e.dailyUsage, func(key string, value any) error {
		rec, err := domain.DecodeDailyUsage(value)
		if err != nil {
			return err
		}
		records[key] = rec
		return nil
	})
	if existing, ok := records[string(id)]; ok && existing.Date == today {
		next.Tokens += existing.Tokens
		next.CostUSD = existing.CostUSD.Add(deltaCostUSD)
		for k, v := range existing.SessionTokens {
			next.SessionTokens[k] += v
		}
	}
	records[string(id)] = next
	e.dailyUsage = json.RawMessage(pairsOf(records, dailyTree))
	f.write(e)
	return next
}

// Noop is an empty, write-discarding Store for tests and for providers with no cache.
type Noop struct{}

// LoadAll implements Store.
func (Noop) LoadAll() map[domain.ProviderID]domain.ProviderState {
	return map[domain.ProviderID]domain.ProviderState{}
}

// Baseline implements Store.
func (Noop) Baseline(domain.ProviderID) *domain.BaselineRecord { return nil }

// MaintainBaseline implements Store.
func (Noop) MaintainBaseline(domain.ProviderID, time.Time, float64) {}

// WithCursors implements Store.
func (Noop) WithCursors(body func(Cursors)) { body(Noop{}) }

// SetTranscriptOffsets implements Cursors.
func (Noop) SetTranscriptOffsets([]domain.TranscriptOffset) {}

// AllTranscriptOffsets implements Cursors.
func (Noop) AllTranscriptOffsets() map[string]domain.TranscriptOffset {
	return map[string]domain.TranscriptOffset{}
}

// AccumulateDailyUsage implements Cursors: the delta passes through unchanged.
func (Noop) AccumulateDailyUsage(_ domain.ProviderID, _ time.Time, deltaTokens int, deltaCostUSD decimal.Decimal, deltaSessionTokens map[string]int) domain.DailyUsageRecord {
	return domain.DailyUsageRecord{Tokens: deltaTokens, CostUSD: deltaCostUSD, SessionTokens: deltaSessionTokens}
}
