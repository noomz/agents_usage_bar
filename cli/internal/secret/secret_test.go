package secret

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestSecretNeverPrints(t *testing.T) {
	s := New("hunter2")
	if s.Reveal() != "hunter2" {
		t.Fatal("Reveal must return the value")
	}
	wrapped := struct{ Key Secret }{s}
	outputs := []string{
		fmt.Sprint(s), fmt.Sprintf("%v", s), fmt.Sprintf("%+v", s), fmt.Sprintf("%#v", s), fmt.Sprintf("%s", s),
		fmt.Sprintf("%q", s), fmt.Sprintf("%x", s), fmt.Sprintf("%v", wrapped), fmt.Sprintf("%+v", wrapped), fmt.Sprintf("%#v", wrapped),
	}
	encoded, err := json.Marshal(wrapped)
	if err != nil {
		t.Fatal(err)
	}
	outputs = append(outputs, string(encoded))
	for _, out := range outputs {
		if strings.Contains(out, "hunter2") || strings.Contains(out, "68756e746572") {
			t.Errorf("secret leaked: %s", out)
		}
	}
}
