// Package settings is `aub settings`: the same knobs as the app's Settings window, stored in
// UserDefaults on macOS and in a JSON file elsewhere.
package settings

import (
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"

	"github.com/noomz/agents_usage_bar/cli/internal/paths"
)

// Store holds typed values under the app's `aub.*` keys. A value is a string, bool, int64,
// or float64: the types the app's UserDefaults accessors expect.
type Store interface {
	Get(key string) (any, bool)
	// All returns every stored key.
	All() map[string]any
	Set(key string, value any) error
	Delete(key string) error
}

// AppDomain is the app's UserDefaults domain on macOS.
const AppDomain = "app.agents-usage-bar"

// Default returns this system's store.
func Default(layout paths.Layout) Store {
	if runtime.GOOS == "darwin" {
		return &Defaults{Domain: AppDomain}
	}
	return &JSONFile{Path: layout.SettingsFile()}
}

// Memory is an in-process Store for tests.
type Memory map[string]any

// Get implements Store.
func (m Memory) Get(key string) (any, bool) { v, ok := m[key]; return v, ok }

// All implements Store.
func (m Memory) All() map[string]any { return m }

// Set implements Store.
func (m Memory) Set(key string, value any) error { m[key] = value; return nil }

// Delete implements Store.
func (m Memory) Delete(key string) error { delete(m, key); return nil }

// JSONFile stores values in one flat JSON object, replaced atomically.
type JSONFile struct {
	Path string
}

func (f *JSONFile) read() (map[string]any, error) {
	data, err := os.ReadFile(f.Path)
	if errors.Is(err, os.ErrNotExist) {
		return map[string]any{}, nil
	}
	if err != nil {
		return nil, err
	}
	d := json.NewDecoder(strings.NewReader(string(data)))
	d.UseNumber()
	var m map[string]any
	if err := d.Decode(&m); err != nil {
		return nil, fmt.Errorf("%s: %w", f.Path, err)
	}
	for k, v := range m {
		if n, ok := v.(json.Number); ok {
			if i, err := n.Int64(); err == nil {
				m[k] = i
			} else if x, err := n.Float64(); err == nil {
				m[k] = x
			}
		}
	}
	return m, nil
}

// All implements Store. An unreadable file reads as empty, like an absent preference; a write
// reports it instead of replacing it.
func (f *JSONFile) All() map[string]any {
	m, err := f.read()
	if err != nil {
		return map[string]any{}
	}
	return m
}

// Get implements Store.
func (f *JSONFile) Get(key string) (any, bool) {
	v, ok := f.All()[key]
	return v, ok
}

func (f *JSONFile) update(change func(map[string]any)) error {
	m, err := f.read()
	if err != nil {
		return err
	}
	change(m)
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	dir := filepath.Dir(f.Path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".settings-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(append(data, '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), f.Path)
}

// Set implements Store.
func (f *JSONFile) Set(key string, value any) error {
	return f.update(func(m map[string]any) { m[key] = value })
}

// Delete implements Store.
func (f *JSONFile) Delete(key string) error {
	return f.update(func(m map[string]any) { delete(m, key) })
}

// Defaults reads and writes a UserDefaults domain through /usr/bin/defaults, so the app's
// preferences daemon stays the single writer and sees changes at once.
type Defaults struct {
	Domain string
	mu     sync.Mutex
	loaded map[string]any
}

const defaultsTool = "/usr/bin/defaults"

// All implements Store.
func (d *Defaults) All() map[string]any {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.loaded != nil {
		return d.loaded
	}
	d.loaded = map[string]any{}
	out, err := exec.Command(defaultsTool, "export", d.Domain, "-").Output()
	if err != nil {
		return d.loaded
	}
	if parsed, err := parsePlistDict(out); err == nil {
		d.loaded = parsed
	}
	return d.loaded
}

// Get implements Store.
func (d *Defaults) Get(key string) (any, bool) {
	v, ok := d.All()[key]
	return v, ok
}

// Set implements Store. Doubles go through a plist literal because `defaults write -float`
// would store a 32-bit value (0.7 reads back as 0.699999988).
func (d *Defaults) Set(key string, value any) error {
	args := []string{"write", d.Domain, key}
	switch v := value.(type) {
	case string:
		args = append(args, "-string", v)
	case bool:
		args = append(args, "-bool", strconv.FormatBool(v))
	case int64:
		args = append(args, "-int", strconv.FormatInt(v, 10))
	case float64:
		args = append(args, "<real>"+strconv.FormatFloat(v, 'g', -1, 64)+"</real>")
	default:
		return fmt.Errorf("unsupported settings value for %s", key)
	}
	if out, err := exec.Command(defaultsTool, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("defaults write %s: %w: %s", key, err, strings.TrimSpace(string(out)))
	}
	d.invalidate()
	return nil
}

// Delete implements Store. An absent key is already deleted.
func (d *Defaults) Delete(key string) error {
	_ = exec.Command(defaultsTool, "delete", d.Domain, key).Run()
	d.invalidate()
	return nil
}

func (d *Defaults) invalidate() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.loaded = nil
}

// parsePlistDict reads the scalars of a top-level XML plist dict. Nested values (the app's
// window frames and notification state) are skipped: no setting reads them.
func parsePlistDict(data []byte) (map[string]any, error) {
	dec := xml.NewDecoder(strings.NewReader(string(data)))
	dec.Strict = false
	out := map[string]any{}
	depth := 0
	key := ""
	for {
		tok, err := dec.Token()
		if errors.Is(err, io.EOF) {
			return out, nil
		}
		if err != nil {
			return nil, err
		}
		start, ok := tok.(xml.StartElement)
		if !ok {
			if end, isEnd := tok.(xml.EndElement); isEnd && (end.Name.Local == "dict" || end.Name.Local == "plist") {
				depth--
			}
			continue
		}
		switch start.Name.Local {
		case "plist", "dict":
			if depth >= 2 {
				if err := dec.Skip(); err != nil {
					return nil, err
				}
				key = ""
				continue
			}
			depth++
		case "key":
			var text string
			if err := dec.DecodeElement(&text, &start); err != nil {
				return nil, err
			}
			key = text
		case "true":
			out[key] = true
			if err := dec.Skip(); err != nil {
				return nil, err
			}
		case "false":
			out[key] = false
			if err := dec.Skip(); err != nil {
				return nil, err
			}
		case "string", "integer", "real":
			var text string
			if err := dec.DecodeElement(&text, &start); err != nil {
				return nil, err
			}
			switch start.Name.Local {
			case "string":
				out[key] = text
			case "integer":
				if i, err := strconv.ParseInt(strings.TrimSpace(text), 10, 64); err == nil {
					out[key] = i
				}
			case "real":
				if x, err := strconv.ParseFloat(strings.TrimSpace(text), 64); err == nil {
					out[key] = x
				}
			}
		default:
			if err := dec.Skip(); err != nil {
				return nil, err
			}
		}
	}
}

// The accessors below reproduce UserDefaults' coercions, so a value the app or a user wrote
// with another type reads the same way it does in the app.

// stringValue is `string(forKey:)`: strings, and the text of numbers.
func stringValue(v any, ok bool) (string, bool) {
	if !ok {
		return "", false
	}
	switch x := v.(type) {
	case string:
		return x, true
	case int64:
		return strconv.FormatInt(x, 10), true
	case float64:
		return strconv.FormatFloat(x, 'g', -1, 64), true
	case bool:
		if x {
			return "1", true
		}
		return "0", true
	}
	return "", false
}

// boolValue is `bool(forKey:)`: a stored number is nonzero; a string is yes, true, or exactly 1.
func boolValue(v any) bool {
	switch x := v.(type) {
	case bool:
		return x
	case int64:
		return x != 0
	case float64:
		return x != 0
	case string:
		lower := strings.ToLower(x)
		return lower == "yes" || lower == "true" || x == "1"
	}
	return false
}

// doubleValue is `object(forKey:) as? Double`.
func doubleValue(v any, ok bool) (float64, bool) {
	if !ok {
		return 0, false
	}
	switch x := v.(type) {
	case float64:
		return x, true
	case int64:
		return float64(x), true
	case bool:
		if x {
			return 1, true
		}
		return 0, true
	}
	return 0, false
}
