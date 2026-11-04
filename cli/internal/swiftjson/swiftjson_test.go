package swiftjson

import "testing"

// Expected bytes were captured from JSONEncoder on macOS.
func TestPrettySortedShape(t *testing.T) {
	got := Encode(map[string]any{"b": "1", "a": []any{}, "c": map[string]any{}, "d": 1.0}, Options{Pretty: true, WithoutEscapeSlashes: true})
	want := "{\n  \"a\" : [\n\n  ],\n  \"b\" : \"1\",\n  \"c\" : {\n\n  },\n  \"d\" : 1\n}"
	if got != want {
		t.Errorf("got %q want %q", got, want)
	}
	if got := Encode([]any{}, Options{Pretty: true}); got != "[\n\n]" {
		t.Errorf("top-level empty array: %q", got)
	}
	if got := Encode(map[string]any{}, Options{Pretty: true}); got != "{\n\n}" {
		t.Errorf("top-level empty object: %q", got)
	}
}

func TestKeySortIsBytewise(t *testing.T) {
	keys := map[string]any{}
	for _, k := range []string{"b", "a", "B", "10", "9", "5h", "7d-opus", "7d", "a/b", "Z", "_x", "a-b", "a_b", "a.b", "ab"} {
		keys[k] = 1
	}
	got := Encode(keys, Options{WithoutEscapeSlashes: true})
	want := `{"10":1,"5h":1,"7d":1,"7d-opus":1,"9":1,"B":1,"Z":1,"_x":1,"a":1,"a-b":1,"a.b":1,"a/b":1,"a_b":1,"ab":1,"b":1}`
	if got != want {
		t.Errorf("got %s", got)
	}
}

func TestStringEscapes(t *testing.T) {
	got := Encode("é\n\t\"\\\x01\x7f/", Options{WithoutEscapeSlashes: true})
	if want := "\"é\\n\\t\\\"\\\\\\u0001\x7f/\""; got != want {
		t.Errorf("got %q want %q", got, want)
	}
	if got := Encode("a/b", Options{}); got != `"a\/b"` {
		t.Errorf("slash: %s", got)
	}
}

func TestDoubleForms(t *testing.T) {
	cases := []struct {
		in           float64
		desc, asJSON string
	}{
		{0.1, "0.1", "0.1"},
		{1, "1.0", "1"},
		{0.30000000000000004, "0.30000000000000004", "0.30000000000000004"},
		{1e-5, "1e-05", "1e-05"},
		{1.5e-5, "1.5e-05", "1.5e-05"},
		{0.0001, "0.0001", "0.0001"},
		{0.00012, "0.00012", "0.00012"},
		{1e16, "1e+16", "1e+16"},
		{9007199254740992, "9007199254740992.0", "9007199254740992"},
		{9007199254740994, "9.007199254740994e+15", "9.007199254740994e+15"},
		{1e21, "1e+21", "1e+21"},
		{123456789012.5, "123456789012.5", "123456789012.5"},
		{1e-300, "1e-300", "1e-300"},
		{5e-324, "5e-324", "5e-324"},
		{100, "100.0", "100"},
		{1e15, "1000000000000000.0", "1000000000000000"},
		{0, "0.0", "0"},
	}
	for _, c := range cases {
		if got := DoubleDescription(c.in); got != c.desc {
			t.Errorf("description %v: %s want %s", c.in, got, c.desc)
		}
		if got := JSONDouble(c.in); got != c.asJSON {
			t.Errorf("json %v: %s want %s", c.in, got, c.asJSON)
		}
	}
}
