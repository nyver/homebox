package auth

import "testing"

func TestPasswordRoundTrip(t *testing.T) {
	hash, err := HashPassword("correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyPassword(hash, "correct horse battery staple") {
		t.Fatal("valid password was rejected")
	}
	if VerifyPassword(hash, "incorrect password") {
		t.Fatal("invalid password was accepted")
	}
}

func TestVerifyPasswordRejectsMalformedHash(t *testing.T) {
	if VerifyPassword("not-a-password-hash", "password") {
		t.Fatal("malformed hash was accepted")
	}
}
