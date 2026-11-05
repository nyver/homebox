package deviceauth

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"testing"
)

// The Dart client builds the same bytes (client/test/account_identity_test.dart);
// this fixed vector keeps the two implementations from drifting apart.
const recoveryStatementVector = "4842585242000100112233445566778899aabbccddeeff" +
	"1e6ed65d77d6364eeaed5a745ba5c4985ae2b700dd85d7cf7f027bdf294a33fc"

func TestRecoveryBundleStatementVector(t *testing.T) {
	statement, err := RecoveryBundleStatement("00112233-4455-6677-8899-aabbccddeeff", []byte("bundle"))
	if err != nil {
		t.Fatal(err)
	}
	if got := hex.EncodeToString(statement); got != recoveryStatementVector {
		t.Fatalf("statement = %s", got)
	}
}

func TestVerifyRecoveryBundle(t *testing.T) {
	public, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	userID := "00112233-4455-6677-8899-aabbccddeeff"
	statement, err := RecoveryBundleStatement(userID, []byte("bundle"))
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(private, statement)
	if err := VerifyRecoveryBundle(public, signature, userID, []byte("bundle")); err != nil {
		t.Fatalf("valid signature rejected: %v", err)
	}
	if VerifyRecoveryBundle(public, signature, userID, []byte("other")) == nil {
		t.Fatal("signature accepted for a different bundle")
	}
	if VerifyRecoveryBundle(public, signature, "ffeeddcc-bbaa-9988-7766-554433221100", []byte("bundle")) == nil {
		t.Fatal("signature accepted for a different account")
	}
	if _, err := RecoveryBundleStatement(userID, nil); err == nil {
		t.Fatal("empty bundle accepted")
	}
}
