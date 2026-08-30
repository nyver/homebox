package config

import "testing"

func TestDefaultsAreSafe(t *testing.T) {
	c := Defaults()
	if err := c.Validate(); err != nil {
		t.Fatalf("defaults must be valid: %v", err)
	}
	if c.Limits.MaxPlaintextFileSize != 500*1024*1024 {
		t.Fatalf("plaintext file limit = %d, want 500 MiB", c.Limits.MaxPlaintextFileSize)
	}
	if c.Limits.MaxCiphertextFileSize != 500*1024*1024+125*16 {
		t.Fatalf("ciphertext file limit = %d, want 500 MiB plus AEAD tags", c.Limits.MaxCiphertextFileSize)
	}
	c.Security.E2EE.ServerDecryptionEnabled = true
	if err := c.Validate(); err == nil {
		t.Fatal("server decryption must be rejected")
	}
}

func TestRejectsInsecureHTTPConfiguration(t *testing.T) {
	c := Defaults()
	c.Security.ApplicationEncryption.RequiredForHTTP = false
	if err := c.Validate(); err == nil {
		t.Fatal("unencrypted HTTP configuration must be rejected")
	}
}

func TestRejectsNonPositiveOrphanBlobGracePeriod(t *testing.T) {
	c := Defaults()
	c.Maintenance.OrphanBlobGraceHours = 0
	if err := c.Validate(); err == nil {
		t.Fatal("non-positive orphan blob grace period must be rejected")
	}
}
