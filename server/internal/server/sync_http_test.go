package server_test

import (
	"context"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/entitlement"
	"github.com/mralexivy/whisperer/server/internal/retention"
	"github.com/mralexivy/whisperer/server/internal/syncplane"
)

const device = "0123456789abcdef0123456789abcdef"

type syncRig struct {
	*rig
	blobs *syncplane.MemoryBlobs
	sp    *syncplane.MemoryStore
	mac   *mac
	acct  string
	token string
}

type staticApple struct{ ans retention.Answer }

func (a staticApple) Status(context.Context, string) (retention.Answer, error) { return a.ans, nil }

func newSyncRig(t *testing.T) *syncRig {
	r := newRig(t, false)
	blobs, sp := syncplane.NewMemoryBlobs(), syncplane.NewMemoryStore()
	r.srv.WithSync(&syncplane.Service{Store: sp, Blobs: blobs, Root: "whisperer", Now: func() time.Time { return *r.clock }})
	m, token := r.signup()
	r.withLibrary(token)
	return &syncRig{rig: r, blobs: blobs, sp: sp, mac: m, acct: r.accountID(m), token: token}
}

func objs(kind string, seq int, size int) map[string]any {
	return map[string]any{"objects": []map[string]any{{"ref": map[string]any{"kind": kind, "device": device, "seq": seq}, "size": size}}}
}

func TestUploadCommitHeadsOverHTTP(t *testing.T) {
	r := newSyncRig(t)
	code, body := r.do("POST", "/v1/sync/upload", objs("changes", 1, 500), r.token)
	if code != 200 {
		t.Fatalf("upload: %d %v", code, body)
	}
	name := body["grants"].([]any)[0].(map[string]any)["name"].(string)
	r.blobs.Put(name, 500, 77)
	code, body = r.do("POST", "/v1/sync/commit", map[string]any{"device": device, "seq": 1, "crc": 77}, r.token)
	if code != 200 || body["version"].(float64) != 1 {
		t.Fatalf("commit: %d %v", code, body)
	}
	code, body = r.do("GET", "/v1/sync/heads?since=0", nil, r.token)
	heads := body["heads"].(map[string]any)
	if code != 200 || heads[device].(map[string]any)["seq"].(float64) != 1 {
		t.Fatalf("heads: %d %v", code, body)
	}
	if _, body = r.do("GET", "/v1/sync/heads?since=1", nil, r.token); body["unchanged"] != true {
		t.Fatalf("an up-to-date poll: %v", body)
	}
	// A gap in the sequence is a 409 that names the head.
	code, body = r.do("POST", "/v1/sync/commit", map[string]any{"device": device, "seq": 5, "crc": 1}, r.token)
	if code != 409 && code != 404 && code != 400 {
		t.Fatalf("gap: %d %v", code, body)
	}
}

func TestSyncObjectsLiveUnderTheAccountIdNotTheTransaction(t *testing.T) {
	r := newSyncRig(t)
	_, body := r.do("POST", "/v1/sync/upload", objs("changes", 1, 10), r.token)
	name := body["grants"].([]any)[0].(map[string]any)["name"].(string)
	want := syncplane.Prefix("whisperer", r.acct, 1) + "changes/" + device + "/000000000001"
	if name != want {
		t.Fatalf("object name %q, want %q", name, want)
	}
}

func TestSyncRoutesNeedASessionAndRefuseForeignNames(t *testing.T) {
	r := newSyncRig(t)
	if code, _ := r.do("POST", "/v1/sync/upload", objs("changes", 1, 10), ""); code != 401 {
		t.Fatalf("no token: %d", code)
	}
	bad := map[string]any{"objects": []map[string]any{{"ref": map[string]any{"kind": "audio", "id": "../../other/e1/audio/00000000000000000000000000000000"}, "size": 10}}}
	if code, body := r.do("POST", "/v1/sync/upload", bad, r.token); code != 400 {
		t.Fatalf("traversal: %d %v", code, body)
	}
}

func TestUploadNeedsALibrary(t *testing.T) {
	r := newRig(t, false)
	r.srv.WithSync(&syncplane.Service{Store: syncplane.NewMemoryStore(), Blobs: syncplane.NewMemoryBlobs(), Root: "whisperer"})
	_, token := r.signup()
	if code, body := r.do("POST", "/v1/sync/upload", objs("changes", 1, 10), token); code != 409 || body["error"] != "library_required" {
		t.Fatalf("no library: %d %v", code, body)
	}
}

func TestARevokedDeviceLosesSyncAtTheNextGrantAndCommit(t *testing.T) {
	r := newSyncRig(t)
	other, otherTok := r.enrolConfirmed()
	if code, _ := r.do("POST", "/v1/sync/upload", objs("changes", 1, 10), otherTok); code != 200 {
		t.Fatal("authorized second device should sync")
	}
	if code, _ := r.do("DELETE", "/v1/devices/"+other.id, nil, r.token); code != 204 {
		t.Fatalf("revoke: %d", code)
	}
	for _, p := range []struct{ method, path string }{{"POST", "/v1/sync/upload"}, {"POST", "/v1/sync/commit"}, {"POST", "/v1/sync/download"}, {"POST", "/v1/sync/delete"}} {
		code, body := r.do(p.method, p.path, objs("changes", 1, 10), otherTok)
		if code != 403 || body["error"] != "device_revoked" {
			t.Errorf("%s with a revoked device (token still valid): %d %v", p.path, code, body)
		}
	}
	if code, _ := r.do("POST", "/v1/sync/upload", objs("changes", 1, 10), r.token); code != 200 {
		t.Fatal("the other device must be unaffected")
	}
}

func TestATokenForAnotherAccountsDeviceIsRefused(t *testing.T) {
	r := newSyncRig(t)
	forged, _ := r.signer.Issue(r.acct, "ffffffffffffffffffffffffffffffff", 1, "active", false, *r.clock) // a device id that is not enrolled
	if code, body := r.do("POST", "/v1/sync/upload", objs("changes", 1, 10), forged); code != 403 || body["error"] != "device_not_authorized" {
		t.Fatalf("unenrolled device in a validly signed token: %d %v", code, body)
	}
}

func TestALapsedSubscriberCanReadAndDeleteButNotWrite(t *testing.T) {
	r := newSyncRig(t)
	_, up := r.do("POST", "/v1/sync/upload", objs("changes", 1, 100), r.token)
	r.blobs.Put(up["grants"].([]any)[0].(map[string]any)["name"].(string), 100, 5)
	r.do("POST", "/v1/sync/commit", map[string]any{"device": device, "seq": 1, "crc": 5}, r.token)

	*r.clock = r.clock.Add(31 * 24 * time.Hour) // the month is paid up; now it has lapsed
	r.token = r.tokenFor(r.acct, r.mac.id)
	if code, body := r.do("POST", "/v1/sync/upload", objs("changes", 2, 100), r.token); code != 403 || body["error"] != "read_only" {
		t.Fatalf("lapsed write: %d %v", code, body)
	}
	if code, body := r.do("POST", "/v1/sync/download", map[string]any{"objects": []map[string]any{{"kind": "changes", "device": device, "seq": 1}}}, r.token); code != 200 {
		t.Fatalf("lapsed read: %d %v", code, body)
	}
	if code, body := r.do("POST", "/v1/sync/delete", map[string]any{"objects": []map[string]any{{"kind": "changes", "device": device, "seq": 1}}}, r.token); code != 200 || body["deleted"].(float64) != 1 {
		t.Fatalf("lapsed delete: %d %v", code, body)
	}
}

func TestSealedAccountsExportTextButNotAudio(t *testing.T) {
	r := newSyncRig(t)
	pre := syncplane.Prefix("whisperer", r.acct, 1)
	r.blobs.Put(pre+"audio/00000000000000000000000000000001", 10, 0)
	r.blobs.Put(pre+"changes/"+device+"/000000000001", 10, 0)
	*r.clock = r.clock.Add(93 * 24 * time.Hour)
	audio := map[string]any{"objects": []map[string]any{{"kind": "audio", "id": "00000000000000000000000000000001"}}}
	text := map[string]any{"objects": []map[string]any{{"kind": "changes", "device": device, "seq": 1}}}
	// Paid to day 30; the standard plan's read-only window runs to day 150 and the seal to day 164.
	// Day 93 is inside the window — audio still works.
	r.token = r.tokenFor(r.acct, r.mac.id)
	if code, _ := r.do("POST", "/v1/sync/download", audio, r.token); code != 200 {
		t.Fatalf("read-only window audio: %d", code)
	}
	*r.clock = r.clock.Add(60 * 24 * time.Hour) // day 153: three days into the seal
	r.token = r.tokenFor(r.acct, r.mac.id)
	if code, body := r.do("POST", "/v1/sync/download", audio, r.token); code != 403 || body["error"] != "sealed" {
		t.Fatalf("sealed audio: %d %v", code, body)
	}
	if code, _ := r.do("POST", "/v1/sync/download", text, r.token); code != 200 {
		t.Fatalf("sealed text must still export: %d", code)
	}
}

func TestAnAppleNotificationRunsTheGuardedSweep(t *testing.T) {
	r := newSyncRig(t)
	later := r.clock.Add(400 * 24 * time.Hour) // the sweeper's clock; Apple's test certificates are only valid near the rig's own
	lapsed := entitlement.FromTransaction(nil, "gone", entitlementTx("9000", later.Add(-300*24*time.Hour)), later.Add(-330*24*time.Hour))
	_ = r.store.Put(t.Context(), lapsed)
	pre := syncplane.Prefix("whisperer", "gone", 1)
	r.blobs.Put(pre+"audio/00000000000000000000000000000001", 10, 0)
	sw := &retention.Sweeper{Entitlements: r.store, Apple: staticApple{}, Blobs: r.blobs, Root: "whisperer",
		Epoch: func(context.Context, string) (int, error) { return 1, nil }, Now: func() time.Time { return later }}
	r.srv.WithSweeper(sw)
	n := notification(r.rig, "DID_RENEW", "sweep-1", r.tx(nil), *r.clock)
	if code, _ := r.do("POST", "/v1/apple/notifications", map[string]string{"signedPayload": n}, ""); code != 200 {
		t.Fatalf("notification: %d", code)
	}
	if r.blobs.Count(pre) != 0 {
		t.Fatal("the lapsed account's data should have been deleted by the sweep (Apple said expired)")
	}
}
