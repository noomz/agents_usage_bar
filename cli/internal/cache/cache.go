// Package cache reads and updates the live cache file the app writes (today.json).
//
// `LoadAll` only reads. Providers call the offset, baseline, and daily-usage methods, exactly
// as the Swift providers write through FileCacheStore during `aub --live`. Those writes keep
// the stored provider rows byte-for-byte, so a Go process never rewrites what the app owns.
package cache

import (
	"bytes"
	"encoding/json"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/noomz/agents_usage_bar/cli/internal/applog"
	"github.com/noomz/agents_usage_bar/cli/internal/decimal"
	"github.com/noomz/agents_usage_bar/cli/internal/domain"
	"github.com/noomz/agents_usage_bar/cli/internal/swiftjson"
)

type Store interface {
	// LoadAll returns every persisted provider row. A missing or unreadable cache is empty.
	LoadAll() map[domain.ProviderID]domain.ProviderState
	// Baseline returns the stored baseline for id, nil when none exists. available is false when
	// the file exists but cannot be used, so "none" cannot be known.
	Baseline(id domain.ProviderID) (record *domain.BaselineRecord, available bool)
	// MaintainBaseline sets a fresh baseline on a new day or a negative delta; otherwise it
	// keeps the baseline and updates LastValue. Never call it inside WithCursors: it takes the
	// same lock. An error means nothing was stored.
	MaintainBaseline(id domain.ProviderID, now time.Time, currentValue float64) error
	// WithCursors runs body holding the cross-process cursor lock. Cursors are reachable only
	// here, so reading them and adding the delta they measure happen under one lock. A second
	// process in between would count the same bytes, and the total would stay doubled until
	// midnight. Body must make no network call. An error means body did not run, and the caller
	// fails its fetch rather than count without the lock.
	WithCursors(body func(Cursors)) error
}

// Cursors is the cursor and daily-total state, valid only inside WithCursors.
type Cursors interface {
	AllTranscriptOffsets() map[string]domain.TranscriptOffset
	// SetTranscriptOffsets upserts cursors keyed by URL in one write.
	SetTranscriptOffsets(offsets []domain.TranscriptOffset)
	// AccumulateDailyUsage adds a poll's delta to id's running total and returns the new
	// total. A new day key restarts the total from the delta.
	AccumulateDailyUsage(id domain.ProviderID, now time.Time, deltaTokens int, deltaCostUSD decimal.Decimal, deltaSessionTokens map[string]int) domain.DailyUsageRecord
}

// File is the production Store, one JSON file written atomically by rename.
type File struct {
	path     string
	dayKeys  *domain.DayKeyOwner
	lockWait time.Duration
	mu       sync.Mutex
	lockErr  error
}

// NewFile opens a cache path. Nothing is created until a provider writes.
func NewFile(path string, dayKeys *domain.DayKeyOwner) *File {
	return &File{path: path, dayKeys: dayKeys, lockWait: defaultLockWait}
}

const (
	currentSchema   = 3
	defaultLockWait = 5 * time.Second
	lockPollEvery   = 50 * time.Millisecond
)

var (
	errLockTimeout = errors.New("cache lock held past the deadline")
	errUnusable    = errors.New("cache file unusable")
)

// lock takes the advisory lock on today.json.lock, shared by every process and goroutine that
// writes the store. The kernel drops it if the process dies. The app's FileCacheStore does not
// take it yet.
//
// This process's fetches queue on mu with no deadline, because a sibling's cold scan is real work
// rather than a stuck holder. The first failure sticks so they do not each wait the deadline in turn.
func (f *File) lock() (unlock func(), err error) {
	f.mu.Lock()
	if f.lockErr != nil {
		defer f.mu.Unlock()
		return nil, f.lockErr
	}
	release, err := f.flock()
	if err != nil {
		defer f.mu.Unlock()
		f.lockErr = err
		return nil, err
	}
	return func() {
		release()
		f.mu.Unlock()
	}, nil
}

func (f *File) flock() (release func(), err error) {
	if err := os.MkdirAll(filepath.Dir(f.path), 0o755); err != nil {
		return func() {}, nil
	}
	file, err := os.OpenFile(f.path+".lock", os.O_RDWR|os.O_CREATE, 0o644)
	if err != nil {
		// flock needs no write access, so a lock file left by another user still excludes.
		file, err = os.OpenFile(f.path+".lock", os.O_RDONLY, 0)
	}
	// Absent and not creatable means the directory is not writable. The store's rename cannot
	// succeed there either, so nothing persists and no total can double.
	if errors.Is(err, os.ErrNotExist) {
		return func() {}, nil
	}
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(f.lockWait)
	for {
		err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		switch {
		case err == nil:
			return func() { file.Close() }, nil
		case errors.Is(err, syscall.EINTR):
			continue
		case !errors.Is(err, syscall.EWOULDBLOCK):
			file.Close()
			return nil, err
		case time.Now().After(deadline):
			file.Close()
			return nil, errLockTimeout
		}
		time.Sleep(lockPollEvery)
	}
}

func (f *File) WithCursors(body func(Cursors)) error {
	unlock, err := f.lock()
	if err != nil {
		return err
	}
	defer unlock()
	body(fileCursors{f})
	return nil
}

// fileCursors is File's Cursors, handed out only under the lock.
type fileCursors struct{ f *File }

// envelope keeps sections raw so a write leaves `providers` exactly as the app wrote it. The
// decoded maps are nil after read and filled by load.
type envelope struct {
	providers   json.RawMessage
	baselines   json.RawMessage
	transcripts json.RawMessage
	dailyUsage  json.RawMessage

	baselineRecords map[string]domain.BaselineRecord
	offsets         map[string]domain.TranscriptOffset
	daily           map[string]domain.DailyUsageRecord
}

func emptyEnvelope() *envelope {
	return &envelope{
		baselineRecords: map[string]domain.BaselineRecord{},
		offsets:         map[string]domain.TranscriptOffset{},
		daily:           map[string]domain.DailyUsageRecord{},
	}
}

type storeState int

const (
	// storeUsable includes a missing file, which the first write creates.
	storeUsable storeState = iota
	// storeCorrupt is a current or older schema that does not decode. Swift and Go both write by
	// atomic rename, so a reader never sees a partial write and this is real damage.
	storeCorrupt
	// storeForeign is a newer schema, whose contents a newer app owns, or a file that cannot be
	// read, whose contents are unknown. It is never written or moved.
	storeForeign
)

// read checks the file's outline only, so `--cached` does not decode 1 MB of transcript cursors.
func (f *File) read() (*envelope, storeState) {
	data, err := os.ReadFile(f.path)
	if errors.Is(err, os.ErrNotExist) {
		return emptyEnvelope(), storeUsable
	}
	if err != nil {
		return nil, storeForeign
	}
	if len(bytes.Trim(data, " \t\r\n\x00")) == 0 {
		return nil, storeCorrupt
	}
	// Anything not shaped like JSON text (a BOM, UTF-16, which holds NUL bytes) may be a file Swift reads, so it stays put.
	if trimmed := bytes.TrimLeft(data, " \t\r\n"); trimmed[0] != '{' || bytes.IndexByte(data, 0) >= 0 {
		return nil, storeForeign
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil {
		return nil, storeCorrupt
	}
	schema, state := parseSchema(top["schemaVersion"])
	if state != storeUsable {
		return nil, state
	}
	// Later schemas add sections, and a reader of an older schema ignores the newer ones.
	required := map[int][]string{
		1: {"providers", "baselines"},
		2: {"providers", "baselines", "transcripts"},
		3: {"providers", "baselines", "transcripts", "dailyUsage"},
	}[schema]
	for _, key := range required {
		if _, ok := top[key]; !ok {
			return nil, storeCorrupt
		}
	}
	e := &envelope{providers: top["providers"], baselines: top["baselines"]}
	if schema >= 2 {
		e.transcripts = top["transcripts"]
	}
	if schema >= 3 {
		e.dailyUsage = top["dailyUsage"]
	}
	return e, storeUsable
}

// parseSchema reads the version as a number, so 3.0 is 3. A version above the current one, or too
// large to parse, belongs to a newer app.
func parseSchema(raw json.RawMessage) (int, storeState) {
	var n json.Number
	if json.Unmarshal(raw, &n) != nil {
		return 0, storeCorrupt
	}
	r, ok := new(big.Rat).SetString(n.String())
	if !ok {
		return 0, storeForeign
	}
	if !r.IsInt() || r.Sign() <= 0 {
		return 0, storeCorrupt
	}
	if r.Cmp(big.NewRat(currentSchema, 1)) > 0 {
		return 0, storeForeign
	}
	return int(r.Num().Int64()), storeUsable
}

// load also decodes what totals depend on. All or nothing, as Swift's decoder is: keeping the good
// half of a section would pair a surviving daily total with lost cursors and recount those files.
// Provider rows stay opaque because no total depends on them and the app owns them.
func (f *File) load() (*envelope, storeState) {
	e, state := f.read()
	if state != storeUsable {
		return e, state
	}
	var err error
	if e.baselineRecords, err = decodeBaselines(e.baselines); err != nil {
		return nil, loadFailure(err)
	}
	if e.offsets, err = decodeOffsets(e.transcripts); err != nil {
		return nil, loadFailure(err)
	}
	if e.daily, err = decodeDaily(e.dailyUsage); err != nil {
		return nil, loadFailure(err)
	}
	if err := pairs(e.providers, func(string, any) error { return nil }); err != nil {
		return nil, storeCorrupt
	}
	return e, storeUsable
}

func loadFailure(err error) storeState {
	if errors.Is(err, domain.ErrIntRange) {
		return storeForeign
	}
	return storeCorrupt
}

// update is load for a lock holder. It moves a corrupt file aside and starts fresh, losing cursors
// and daily totals together, so the next read recounts today once. ok is false when the store
// cannot be written.
func (f *File) update() (e *envelope, ok bool) {
	e, state := f.load()
	if state != storeCorrupt {
		return e, state == storeUsable
	}
	if os.Rename(f.path, f.path+".corrupt") != nil {
		return nil, false
	}
	applog.Logger.Warn("cache file corrupt; moved aside and starting fresh")
	return emptyEnvelope(), true
}

func (f *File) write(e *envelope) error {
	object := map[string]any{
		"schemaVersion": currentSchema,
		"providers":     rawOr(e.providers, "[]"),
		"baselines":     rawOr(e.baselines, "[]"),
		"transcripts":   rawOr(e.transcripts, "{}"),
		"dailyUsage":    rawOr(e.dailyUsage, "[]"),
	}
	data := []byte(swiftjson.Encode(object, swiftjson.Options{}))
	if err := os.MkdirAll(filepath.Dir(f.path), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(f.path), ".today-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), f.path)
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

func (f *File) LoadAll() map[domain.ProviderID]domain.ProviderState {
	e, state := f.read()
	states := map[domain.ProviderID]domain.ProviderState{}
	if state != storeUsable {
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

func decodeBaselines(raw json.RawMessage) (map[string]domain.BaselineRecord, error) {
	out := map[string]domain.BaselineRecord{}
	err := pairs(raw, func(key string, value any) error {
		rec, err := domain.DecodeBaseline(value)
		if err != nil {
			return err
		}
		out[key] = rec
		return nil
	})
	return out, err
}

func decodeDaily(raw json.RawMessage) (map[string]domain.DailyUsageRecord, error) {
	out := map[string]domain.DailyUsageRecord{}
	err := pairs(raw, func(key string, value any) error {
		rec, err := domain.DecodeDailyUsage(value)
		if err != nil {
			return err
		}
		out[key] = rec
		return nil
	})
	return out, err
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

func (f *File) Baseline(id domain.ProviderID) (*domain.BaselineRecord, bool) {
	e, state := f.load()
	if state != storeUsable {
		return nil, false
	}
	if rec, ok := e.baselineRecords[string(id)]; ok {
		return &rec, true
	}
	return nil, true
}

func (f *File) MaintainBaseline(id domain.ProviderID, now time.Time, currentValue float64) error {
	unlock, err := f.lock()
	if err != nil {
		return err
	}
	defer unlock()
	e, ok := f.update()
	if !ok {
		return errUnusable
	}
	today := f.dayKeys.KeyFor(now)
	existing, ok := e.baselineRecords[string(id)]
	base := currentValue
	if ok && existing.Date == today && currentValue >= existing.Value {
		base = existing.Value
	}
	e.baselineRecords[string(id)] = domain.BaselineRecord{Value: base, Date: today, LastValue: currentValue, LastUpdated: now}
	e.baselines = json.RawMessage(pairsOf(e.baselineRecords, baselineTree))
	return f.write(e)
}

func decodeOffsets(raw json.RawMessage) (map[string]domain.TranscriptOffset, error) {
	out := map[string]domain.TranscriptOffset{}
	if len(raw) == 0 {
		return out, nil
	}
	tree, err := domain.ParseJSON(raw)
	if err != nil {
		return nil, err
	}
	m, ok := tree.(map[string]any)
	if !ok {
		return nil, errors.New("expected an object of cursors")
	}
	for key, value := range m {
		offset, err := domain.DecodeTranscriptOffset(value)
		if err != nil {
			return nil, err
		}
		out[key] = offset
	}
	return out, nil
}

func (c fileCursors) AllTranscriptOffsets() map[string]domain.TranscriptOffset {
	e, ok := c.f.update()
	if !ok {
		return map[string]domain.TranscriptOffset{}
	}
	return e.offsets
}

func (c fileCursors) SetTranscriptOffsets(offsets []domain.TranscriptOffset) {
	if len(offsets) == 0 {
		return
	}
	f := c.f
	e, ok := f.update()
	if !ok {
		return
	}
	for _, o := range offsets {
		e.offsets[o.URL] = o
	}
	tree := make(map[string]any, len(e.offsets))
	for k, o := range e.offsets {
		tree[k] = map[string]any{"url": o.URL, "byteOffset": o.ByteOffset, "lastModified": domain.RefSeconds(o.LastModified)}
	}
	e.transcripts = json.RawMessage(swiftjson.Encode(tree, swiftjson.Options{}))
	_ = f.write(e)
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

func (c fileCursors) AccumulateDailyUsage(id domain.ProviderID, now time.Time, deltaTokens int, deltaCostUSD decimal.Decimal, deltaSessionTokens map[string]int) domain.DailyUsageRecord {
	f := c.f
	today := f.dayKeys.KeyFor(now)
	next := domain.DailyUsageRecord{Date: today, Tokens: deltaTokens, CostUSD: deltaCostUSD, SessionTokens: map[string]int{}}
	for k, v := range deltaSessionTokens {
		next.SessionTokens[k] = v
	}
	// With no readable cursors the delta is the whole day, so it is already the total.
	e, ok := f.update()
	if !ok {
		return next
	}
	if existing, ok := e.daily[string(id)]; ok && existing.Date == today {
		next.Tokens += existing.Tokens
		next.CostUSD = existing.CostUSD.Add(deltaCostUSD)
		for k, v := range existing.SessionTokens {
			next.SessionTokens[k] += v
		}
	}
	e.daily[string(id)] = next
	e.dailyUsage = json.RawMessage(pairsOf(e.daily, dailyTree))
	_ = f.write(e)
	return next
}

// Noop is an empty, write-discarding Store for tests and for providers with no cache.
type Noop struct{}

func (Noop) LoadAll() map[domain.ProviderID]domain.ProviderState {
	return map[domain.ProviderID]domain.ProviderState{}
}

func (Noop) Baseline(domain.ProviderID) (*domain.BaselineRecord, bool) { return nil, true }

func (Noop) MaintainBaseline(domain.ProviderID, time.Time, float64) error { return nil }

func (Noop) WithCursors(body func(Cursors)) error {
	body(Noop{})
	return nil
}

func (Noop) SetTranscriptOffsets([]domain.TranscriptOffset) {}

func (Noop) AllTranscriptOffsets() map[string]domain.TranscriptOffset {
	return map[string]domain.TranscriptOffset{}
}

// AccumulateDailyUsage passes the delta through unchanged.
func (Noop) AccumulateDailyUsage(_ domain.ProviderID, _ time.Time, deltaTokens int, deltaCostUSD decimal.Decimal, deltaSessionTokens map[string]int) domain.DailyUsageRecord {
	return domain.DailyUsageRecord{Tokens: deltaTokens, CostUSD: deltaCostUSD, SessionTokens: deltaSessionTokens}
}
