package ollamacloud

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Seed 0x01×32 is a throwaway vector shared with the Swift tests, not anyone's key.
const fixedPublicKeyField = "AAAAC3NzaC1lZDI1NTE5AAAAIIqI4910CfGV/VLbLTy6XXLKZwm/HZQSG/N0iAG0D29c"

var (
	fixedSeed = []byte(strings.Repeat("\x01", 32))
	fixedNow  = time.Unix(1_700_000_000, 0)
)

type keyOptions struct {
	cipher, keyType   string
	check1, check2    uint32
	corruptPublicHalf bool
	outerSeed         []byte
}

// encodeKey builds a synthetic container. Neutral markers keep a real private-key header out of
// the repo, and the parser ignores `-----` lines.
func encodeKey(seed []byte, o keyOptions) string {
	if o.cipher == "" {
		o.cipher = "none"
	}
	if o.keyType == "" {
		o.keyType = sshEd25519
	}
	if o.check1 == 0 && o.check2 == 0 {
		o.check1, o.check2 = 0x5EED5EED, 0x5EED5EED
	}
	public := []byte(ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey))
	secretPublic := append([]byte(nil), public...)
	if o.corruptPublicHalf {
		secretPublic[0] ^= 0xFF
	}
	private := binary.BigEndian.AppendUint32(binary.BigEndian.AppendUint32(nil, o.check1), o.check2)
	private = append(private, sshString([]byte(o.keyType))...)
	private = append(private, sshString(public)...)
	private = append(private, sshString(append(append([]byte(nil), seed...), secretPublic...))...)
	private = append(private, sshString([]byte("test"))...)
	for pad := byte(1); len(private)%8 != 0; pad++ {
		private = append(private, pad)
	}
	outer := public
	if o.outerSeed != nil {
		outer = ed25519.NewKeyFromSeed(o.outerSeed).Public().(ed25519.PublicKey)
	}
	out := []byte(opensshMagic)
	out = append(out, sshString([]byte(o.cipher))...)
	out = append(out, sshString([]byte("none"))...)
	out = append(out, sshString(nil)...)
	out = binary.BigEndian.AppendUint32(out, 1)
	out = append(out, sshString(append(sshString([]byte(sshEd25519)), sshString(outer)...))...)
	out = append(out, sshString(private)...)
	b64 := base64.StdEncoding.EncodeToString(out)
	var lines []string
	for len(b64) > 70 {
		lines, b64 = append(lines, b64[:70]), b64[70:]
	}
	lines = append(lines, b64)
	return "-----BEGIN TEST KEY-----\n" + strings.Join(lines, "\n") + "\n-----END TEST KEY-----\n"
}

func fixedSigner(t *testing.T) *signer {
	t.Helper()
	s, err := parseOpenSSH(encodeKey(fixedSeed, keyOptions{}))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestParseRefusals(t *testing.T) {
	good := encodeKey(fixedSeed, keyOptions{})
	raw, _ := base64.StdEncoding.DecodeString(strings.Join(strings.Split(strings.TrimSpace(good), "\n")[1:len(strings.Split(strings.TrimSpace(good), "\n"))-1], ""))
	for _, tc := range []struct {
		name, text string
		want       error
	}{
		{"encrypted", encodeKey(fixedSeed, keyOptions{cipher: "aes256-ctr"}), errEncrypted},
		{"wrong key type", encodeKey(fixedSeed, keyOptions{keyType: "ssh-rsa"}), errUnsupportedType},
		{"check int mismatch", encodeKey(fixedSeed, keyOptions{check1: 1, check2: 2}), errMalformed},
		{"mismatched public half", encodeKey(fixedSeed, keyOptions{corruptPublicHalf: true}), errMalformed},
		{"outer blob names another key", encodeKey(fixedSeed, keyOptions{outerSeed: []byte(strings.Repeat("\x02", 32))}), errMalformed},
		{"empty", "", errMalformed},
		{"not base64", "not base64 !!", errMalformed},
		{"wrong magic", base64.StdEncoding.EncodeToString([]byte("openssh-key-v2\x00")), errMalformed},
		{"truncated", base64.StdEncoding.EncodeToString(raw[:len(raw)/2]), errMalformed},
	} {
		if _, err := parseOpenSSH(tc.text); !errors.Is(err, tc.want) {
			t.Errorf("%s: %v", tc.name, err)
		}
	}
}

func TestParseAccepted(t *testing.T) {
	pem := encodeKey(fixedSeed, keyOptions{})
	var bare []string
	for _, line := range strings.Split(pem, "\n") {
		if !strings.HasPrefix(line, "-----") {
			bare = append(bare, line)
		}
	}
	for name, text := range map[string]string{"pem": pem, "no markers": strings.Join(bare, "\n"), "crlf": strings.ReplaceAll(pem, "\n", "\r\n")} {
		s, err := parseOpenSSH(text)
		if err != nil || s.publicKeyField != fixedPublicKeyField {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestLoadSigner(t *testing.T) {
	dir := t.TempDir()
	if loadSigner(filepath.Join(dir, "missing")) != nil {
		t.Error("missing file loaded")
	}
	path := filepath.Join(dir, "key")
	if err := os.WriteFile(path, []byte(encodeKey(fixedSeed, keyOptions{})), 0o600); err != nil {
		t.Fatal(err)
	}
	if s := loadSigner(path); s == nil || s.publicKeyField != fixedPublicKeyField {
		t.Errorf("valid key: %v", s)
	}
	if err := os.WriteFile(path, []byte(encodeKey(fixedSeed, keyOptions{cipher: "aes256-ctr"})), 0o600); err != nil {
		t.Fatal(err)
	}
	if loadSigner(path) != nil {
		t.Error("encrypted key loaded")
	}
	if got := deviceKeyPath("/tmp/home"); got != "/tmp/home/.ollama/id_ed25519" {
		t.Error(got)
	}
}

func TestSign(t *testing.T) {
	s := fixedSigner(t)
	public := ed25519.NewKeyFromSeed(fixedSeed).Public().(ed25519.PublicKey)
	for _, tc := range []struct {
		name, method, in, url, challenge string
	}{
		{"get", "GET", "https://ollama.com/api/usage", "https://ollama.com/api/usage?ts=1700000000", "GET,/api/usage?ts=1700000000"},
		{"post", "POST", "https://ollama.com/api/me", "https://ollama.com/api/me?ts=1700000000", "POST,/api/me?ts=1700000000"},
		{"replaces ts, keeps query", "GET", "https://ollama.com/api/usage?a=1&ts=5", "https://ollama.com/api/usage?a=1&ts=1700000000", "GET,/api/usage?a=1&ts=1700000000"},
		{"sorted and form escaped", "GET", "https://ollama.com/api/usage?z=1&a=b%2Bc+d", "https://ollama.com/api/usage?a=b%2Bc+d&ts=1700000000&z=1", "GET,/api/usage?a=b%2Bc+d&ts=1700000000&z=1"},
	} {
		signed, auth, err := s.sign(tc.method, tc.in, fixedNow)
		if err != nil {
			t.Fatal(err)
		}
		if signed != tc.url {
			t.Errorf("%s: url %s", tc.name, signed)
		}
		u, _ := url.Parse(signed)
		if got := challenge(tc.method, u); got != tc.challenge {
			t.Errorf("%s: challenge %s", tc.name, got)
		}
		field, sig, ok := strings.Cut(auth, ":")
		if !ok || field != fixedPublicKeyField {
			t.Errorf("%s: header field", tc.name)
		}
		raw, err := base64.StdEncoding.DecodeString(sig)
		if err != nil || len(raw) != ed25519.SignatureSize || !ed25519.Verify(public, []byte(tc.challenge), raw) {
			t.Errorf("%s: signature does not verify", tc.name)
		}
	}
}

// The Go vector matches an independent RFC 8032 implementation and verifies under CryptoKit.
// CryptoKit randomizes its own signatures, so byte equality with Swift cannot exist; the second
// vector is a CryptoKit signature over the same challenge that Go must accept.
func TestSignatureVectors(t *testing.T) {
	const (
		message   = "GET,/api/usage?ts=1700000000"
		rfc8032   = "j7Yd/hG1/lsBWkjCp+9Q7015qqjKejV/1q/BqJRxLDpkWXtsnpZZqxREQvmNrOmu48S5ZefsP1g8DccB8XLRDQ=="
		cryptoKit = "7xVh9z/kplDwIk1wAT6etNGa34pVOybfjwtXuxWnMHEyqXGdY/Kp+8owFsZPjxmIhQIqfc3CkTSre8c+XJ8jBQ=="
	)
	_, auth, err := fixedSigner(t).sign("GET", "https://ollama.com/api/usage", fixedNow)
	if err != nil {
		t.Fatal(err)
	}
	if _, sig, _ := strings.Cut(auth, ":"); sig != rfc8032 {
		t.Errorf("signature %s", sig)
	}
	raw, err := base64.StdEncoding.DecodeString(cryptoKit)
	if err != nil {
		t.Fatal(err)
	}
	if !ed25519.Verify(ed25519.NewKeyFromSeed(fixedSeed).Public().(ed25519.PublicKey), []byte(message), raw) {
		t.Error("CryptoKit signature did not verify")
	}
}

func TestSignerRedacted(t *testing.T) {
	s := fixedSigner(t)
	c := credential{device: s}
	seed := base64.StdEncoding.EncodeToString(fixedSeed)
	for _, text := range []string{fmt.Sprint(s), fmt.Sprintf("%+v", *s), fmt.Sprintf("%#v", *s), fmt.Sprintf("%x", *s), fmt.Sprintf("%+v", c), fmt.Sprintf("%#v", c)} {
		if strings.Contains(text, seed) || strings.Contains(text, string(s.key)) || strings.Contains(text, fmt.Sprintf("%x", []byte(s.key))) {
			t.Errorf("key material in %q", text)
		}
	}
}
