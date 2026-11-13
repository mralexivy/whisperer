package apple_test

import (
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/mralexivy/whisperer/server/internal/apple"
	"github.com/mralexivy/whisperer/server/internal/testkit"
)

var now = time.Date(2026, 11, 13, 12, 0, 0, 0, time.UTC)

func TestEmbeddedRootIsAppleRootCAG3(t *testing.T) {
	const want = "63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79"
	if got := apple.RootFingerprint(); got != want {
		t.Fatalf("root fingerprint %s, want %s", got, want)
	}
	if _, err := apple.NewVerifier(); err != nil {
		t.Fatal(err)
	}
}

func TestVerifiesAChainedTransactionAndDecodesIt(t *testing.T) {
	a := testkit.New(t, now)
	jws := a.JWS(t, map[string]any{
		"originalTransactionId": "1000", "transactionId": "1001", "bundleId": "com.ivy.whisperer",
		"productId": "cloud.monthly", "environment": "Production",
		"expiresDate": now.Add(30 * 24 * time.Hour).UnixMilli(), "signedDate": now.UnixMilli(),
	})
	tx, err := a.Verifier.Transaction(jws)
	if err != nil {
		t.Fatal(err)
	}
	if tx.OriginalTransactionID != "1000" || tx.ProductID != "cloud.monthly" || tx.BundleID != "com.ivy.whisperer" {
		t.Fatalf("decoded wrong: %+v", tx)
	}
}

func TestRejectsAForgery(t *testing.T) {
	a := testkit.New(t, now)
	forged := a.JWSWith(t, map[string]any{"originalTransactionId": "1", "signedDate": now.UnixMilli()}, testkit.OtherKey(t), true)
	if _, err := a.Verifier.Transaction(forged); !errors.Is(err, apple.ErrSignature) {
		t.Fatalf("want ErrSignature, got %v", err)
	}
}

func TestRejectsATamperedPayload(t *testing.T) {
	a := testkit.New(t, now)
	good := a.JWS(t, map[string]any{"originalTransactionId": "1", "productId": "a", "signedDate": now.UnixMilli()})
	other := a.JWS(t, map[string]any{"originalTransactionId": "1", "productId": "b", "signedDate": now.UnixMilli()})
	parts, otherParts := strings.Split(good, "."), strings.Split(other, ".")
	tampered := parts[0] + "." + otherParts[1] + "." + parts[2]
	if _, err := a.Verifier.Transaction(tampered); err == nil {
		t.Fatal("a payload swapped under an old signature must not verify")
	}
}

func TestRejectsAChainThatDoesNotLeadToTheRoot(t *testing.T) {
	a, impostor := testkit.New(t, now), testkit.New(t, now)
	jws := impostor.JWS(t, map[string]any{"originalTransactionId": "1", "signedDate": now.UnixMilli()})
	if _, err := a.Verifier.Transaction(jws); !errors.Is(err, apple.ErrUntrusted) {
		t.Fatalf("want ErrUntrusted, got %v", err)
	}
}

func TestRejectsAMissingIntermediate(t *testing.T) {
	a := testkit.New(t, now)
	jws := a.JWSWith(t, map[string]any{"originalTransactionId": "1", "signedDate": now.UnixMilli()}, a.LeafKey, false)
	if _, err := a.Verifier.Transaction(jws); !errors.Is(err, apple.ErrMalformed) {
		t.Fatalf("want ErrMalformed, got %v", err)
	}
}

func TestChainIsJudgedAtTheTimeAppleSigned(t *testing.T) {
	a := testkit.New(t, now)
	// Signed 20 days ago — the leaf (valid from 30 days ago) was valid then; the server's clock is far past it.
	signed := now.Add(-20 * 24 * time.Hour)
	jws := a.JWS(t, map[string]any{"originalTransactionId": "1", "signedDate": signed.UnixMilli()})
	a.Now = now.Add(400 * 24 * time.Hour) // leaf has expired by now
	if _, err := a.Verifier.Transaction(jws); err != nil {
		t.Fatalf("an old genuine transaction must still verify: %v", err)
	}
}

func TestRejectsAPayloadSignedInTheFuture(t *testing.T) {
	a := testkit.New(t, now)
	jws := a.JWS(t, map[string]any{"originalTransactionId": "1", "signedDate": now.Add(time.Hour).UnixMilli()})
	if _, err := a.Verifier.Transaction(jws); err == nil {
		t.Fatal("a signedDate an hour ahead must be refused")
	}
}

func TestRejectsGarbage(t *testing.T) {
	a := testkit.New(t, now)
	for _, bad := range []string{"", "a.b", "a.b.c", "x.y.z.w", "e30.e30.e30"} {
		if _, err := a.Verifier.Transaction(bad); !errors.Is(err, apple.ErrMalformed) {
			t.Errorf("%q: want ErrMalformed, got %v", bad, err)
		}
	}
}

func TestDecodesANotification(t *testing.T) {
	a := testkit.New(t, now)
	inner := a.JWS(t, map[string]any{"originalTransactionId": "9", "signedDate": now.UnixMilli()})
	outer := a.JWS(t, map[string]any{
		"notificationType": "DID_RENEW", "notificationUUID": "u-1", "signedDate": now.UnixMilli(),
		"data": map[string]any{"environment": "Production", "bundleId": "com.ivy.whisperer", "signedTransactionInfo": inner},
	})
	n, err := a.Verifier.Notification(outer)
	if err != nil {
		t.Fatal(err)
	}
	tx, err := a.Verifier.Transaction(n.Data.SignedTransactionInfo)
	if err != nil || n.NotificationType != "DID_RENEW" || tx.OriginalTransactionID != "9" {
		t.Fatalf("notification decode: %+v %+v %v", n, tx, err)
	}
}
