// Package syncplane is the control plane of Whisperer Cloud sync: who may put which encrypted object where,
// how much they may store, and which change batches exist. It never sees plaintext and never proxies a byte —
// the Mac talks to Cloud Storage through URLs this package asks a Signer for.
//
// Object names are built here from the authenticated account; a client only chooses the final path
// component, and only from a strict alphabet, so no request can name another user's object.
package syncplane

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Kinds of object a library holds.
const (
	KindChange   = "changes"   // changes/{device}/{seq:012d}
	KindSnapshot = "snapshots" // snapshots/{id}
	KindAudio    = "audio"     // audio/{id}
	KindMeeting  = "meetings"  // meetings/{id}
)

var ErrBadName = errors.New("syncplane: invalid object name")

// Prefix is everything one library epoch owns in the bucket.
func Prefix(root, account string, epoch int) string {
	return fmt.Sprintf("%s/users/%s/e%d/", root, account, epoch)
}

func isHex(s string, n int) bool {
	if len(s) != n {
		return false
	}
	for _, c := range s {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// Ref is what a client may say about an object: its kind and the parts the server then validates.
type Ref struct {
	Kind   string `json:"kind"`
	Device string `json:"device,omitempty"` // KindChange: 32 hex chars
	Seq    int64  `json:"seq,omitempty"`    // KindChange: >= 1
	ID     string `json:"id,omitempty"`     // others: 32 hex chars
}

// Name builds the full object name for a ref under `prefix`.
func (r Ref) Name(prefix string) (string, error) {
	switch r.Kind {
	case KindChange:
		if !isHex(r.Device, 32) || r.Seq < 1 || r.Seq > 999_999_999_999 {
			return "", ErrBadName
		}
		return prefix + "changes/" + r.Device + "/" + fmt.Sprintf("%012d", r.Seq), nil
	case KindSnapshot, KindAudio, KindMeeting:
		if !isHex(r.ID, 32) {
			return "", ErrBadName
		}
		return prefix + r.Kind + "/" + r.ID, nil
	}
	return "", ErrBadName
}

// ParseName is the inverse of Name for names under `prefix`. A name outside the prefix, with traversal, or
// with a malformed tail is refused.
func ParseName(prefix, name string) (Ref, error) {
	rest, ok := strings.CutPrefix(name, prefix)
	if !ok || strings.Contains(rest, "..") {
		return Ref{}, ErrBadName
	}
	parts := strings.Split(rest, "/")
	var ref Ref
	switch {
	case len(parts) == 3 && parts[0] == KindChange:
		seq, err := strconv.ParseInt(parts[2], 10, 64)
		if err != nil || len(parts[2]) != 12 {
			return Ref{}, ErrBadName
		}
		ref = Ref{Kind: KindChange, Device: parts[1], Seq: seq}
	case len(parts) == 2 && (parts[0] == KindSnapshot || parts[0] == KindAudio || parts[0] == KindMeeting):
		ref = Ref{Kind: parts[0], ID: parts[1]}
	default:
		return Ref{}, ErrBadName
	}
	if n, err := ref.Name(prefix); err != nil || n != name {
		return Ref{}, ErrBadName
	}
	return ref, nil
}
