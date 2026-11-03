package ollamacloud

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The ways a device key is refused. All of them mean "no device credential".
var (
	errMalformed       = errors.New("malformed device key")
	errEncrypted       = errors.New("encrypted device key")
	errUnsupportedType = errors.New("unsupported device key type")
)

const (
	redactedSigner = "OllamaDeviceSigner(<redacted>)"
	sshEd25519     = "ssh-ed25519"
	opensshMagic   = "openssh-key-v1\x00"
)

// signer signs ollama.com requests with the `ollama signin` key, as Ollama's own client does.
// Only unencrypted OpenSSH ed25519 containers are accepted. Every formatter is redacted.
type signer struct {
	publicKeyField string
	key            ed25519.PrivateKey
}

func (signer) String() string   { return redactedSigner }
func (signer) GoString() string { return redactedSigner }

// Format redacts every verb.
func (signer) Format(f fmt.State, _ rune) { _, _ = f.Write([]byte(redactedSigner)) }

// LogValue redacts structured logs.
func (signer) LogValue() slog.Value { return slog.StringValue(redactedSigner) }

func deviceKeyPath(home string) string { return filepath.Join(home, ".ollama", "id_ed25519") }

// loadSigner is nil when the file is absent, unreadable, encrypted, or not ed25519.
func loadSigner(path string) *signer {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	s, err := parseOpenSSH(string(data))
	if err != nil {
		return nil
	}
	return s
}

type sshReader struct{ buf []byte }

func (r *sshReader) bytes(n int) ([]byte, error) {
	if n < 0 || n > len(r.buf) {
		return nil, errMalformed
	}
	out := r.buf[:n]
	r.buf = r.buf[n:]
	return out, nil
}

func (r *sshReader) uint32() (int, error) {
	b, err := r.bytes(4)
	if err != nil {
		return 0, err
	}
	return int(binary.BigEndian.Uint32(b)), nil
}

func (r *sshReader) string() ([]byte, error) {
	n, err := r.uint32()
	if err != nil {
		return nil, err
	}
	return r.bytes(n)
}

func sshString(b []byte) []byte {
	return append(binary.BigEndian.AppendUint32(nil, uint32(len(b))), b...)
}

func parseOpenSSH(text string) (*signer, error) {
	var body strings.Builder
	for _, line := range strings.FieldsFunc(text, func(c rune) bool { return c == '\n' || c == '\r' }) {
		if !strings.HasPrefix(line, "-----") {
			body.WriteString(line)
		}
	}
	raw, err := base64.StdEncoding.DecodeString(body.String())
	if err != nil {
		return nil, errMalformed
	}
	r := &sshReader{raw}
	magic, err := r.bytes(len(opensshMagic))
	if err != nil || string(magic) != opensshMagic {
		return nil, errMalformed
	}
	cipher, err := r.string()
	if err != nil {
		return nil, err
	}
	if string(cipher) != "none" {
		return nil, errEncrypted
	}
	for range 2 { // kdfname, kdfoptions
		if _, err := r.string(); err != nil {
			return nil, err
		}
	}
	if n, err := r.uint32(); err != nil || n != 1 {
		return nil, errMalformed
	}
	publicBlob, err := r.string()
	if err != nil {
		return nil, err
	}
	private, err := r.string()
	if err != nil {
		return nil, err
	}
	p := &sshReader{private}
	check1, err := p.uint32()
	if err != nil {
		return nil, err
	}
	check2, err := p.uint32()
	if err != nil {
		return nil, err
	}
	if check1 != check2 {
		return nil, errMalformed
	}
	keyType, err := p.string()
	if err != nil {
		return nil, err
	}
	if string(keyType) != sshEd25519 {
		return nil, errUnsupportedType
	}
	publicKey, err := p.string()
	if err != nil {
		return nil, err
	}
	secretPart, err := p.string()
	if err != nil {
		return nil, err
	}
	if len(publicKey) != ed25519.PublicKeySize || len(secretPart) != ed25519.PrivateKeySize || !bytes.Equal(secretPart[32:], publicKey) {
		return nil, errMalformed
	}
	// The header's public blob must name the same key, or the signature would go out under the
	// wrong public key.
	if !bytes.Equal(publicBlob, append(sshString([]byte(sshEd25519)), sshString(publicKey)...)) {
		return nil, errMalformed
	}
	key := ed25519.NewKeyFromSeed(secretPart[:ed25519.SeedSize])
	if !bytes.Equal(key.Public().(ed25519.PublicKey), publicKey) {
		return nil, errMalformed
	}
	return &signer{publicKeyField: base64.StdEncoding.EncodeToString(publicBlob), key: key}, nil
}

// sign adds ts=<unix seconds> to the query, replacing any existing ts, and returns the signed
// URL and its Authorization value. The server rebuilds the challenge from Go's Values.Encode
// form, which is the form used here.
func (s *signer) sign(method, rawURL string, now time.Time) (signedURL, authorization string, err error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return "", "", err
	}
	q := u.Query()
	q.Set("ts", strconv.FormatInt(now.Unix(), 10))
	u.RawQuery = q.Encode()
	signature := ed25519.Sign(s.key, []byte(challenge(method, u)))
	return u.String(), s.publicKeyField + ":" + base64.StdEncoding.EncodeToString(signature), nil
}

func challenge(method string, u *url.URL) string { return method + "," + u.RequestURI() }
