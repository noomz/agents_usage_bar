package claude

import (
	"bytes"
	"encoding/json"
	"path/filepath"
	"strings"
	"time"
)

type transcriptRecord struct {
	timestamp           time.Time
	model               *string
	inputTokens         int
	outputTokens        int
	cacheCreationTokens int
	cacheReadTokens     int
	requestID           *string
}

func (r transcriptRecord) totalTokens() int {
	return r.inputTokens + r.outputTokens + r.cacheCreationTokens + r.cacheReadTokens
}

var assistantMarker = []byte(`"type":"assistant"`)

// decodeTranscript returns false for anything but a usable assistant line. The marker test skips
// the JSON parse for nearly every line, and the fields are kept raw so a tool result megabytes
// long inside an assistant line is not decoded into values nothing reads.
func decodeTranscript(line []byte) (transcriptRecord, bool) {
	if !bytes.Contains(line, assistantMarker) {
		return transcriptRecord{}, false
	}
	var top map[string]json.RawMessage
	if json.Unmarshal(line, &top) != nil {
		return transcriptRecord{}, false
	}
	if kind := stringField(top["type"]); kind == nil || *kind != "assistant" {
		return transcriptRecord{}, false
	}
	stamp := stringField(top["timestamp"])
	if stamp == nil {
		return transcriptRecord{}, false
	}
	timestamp, err := time.Parse(time.RFC3339Nano, *stamp)
	if err != nil {
		return transcriptRecord{}, false
	}
	var message, usage map[string]json.RawMessage
	if json.Unmarshal(top["message"], &message) != nil || message == nil {
		return transcriptRecord{}, false
	}
	if json.Unmarshal(message["usage"], &usage) != nil || usage == nil {
		return transcriptRecord{}, false
	}
	return transcriptRecord{
		timestamp:           timestamp,
		model:               stringField(message["model"]),
		inputTokens:         intField(usage["input_tokens"]),
		outputTokens:        intField(usage["output_tokens"]),
		cacheCreationTokens: intField(usage["cache_creation_input_tokens"]),
		cacheReadTokens:     intField(usage["cache_read_input_tokens"]),
		requestID:           stringField(top["requestId"]),
	}, true
}

func stringField(raw json.RawMessage) *string {
	var s *string
	if len(raw) == 0 || json.Unmarshal(raw, &s) != nil {
		return nil
	}
	return s
}

// intField is `as? Int ?? 0` on a JSONSerialization value: a whole number or a boolean converts,
// anything else is 0.
func intField(raw json.RawMessage) int {
	var v any
	if len(raw) == 0 || json.Unmarshal(raw, &v) != nil {
		return 0
	}
	switch n := v.(type) {
	case float64:
		if n == float64(int(n)) {
			return int(n)
		}
	case bool:
		if n {
			return 1
		}
	}
	return 0
}

// sessionID is the session a transcript belongs to: `<project>/<id>.jsonl`, or a subagent's
// `<project>/<id>/subagents/<agent>.jsonl`. ccs instances share one projects directory, so the
// session ID, not the root, joins a transcript to its account.
func sessionID(path string) string {
	parent := filepath.Dir(path)
	if filepath.Base(parent) == "subagents" {
		return filepath.Base(filepath.Dir(parent))
	}
	return strings.TrimSuffix(filepath.Base(path), filepath.Ext(path))
}
