package config

import "testing"

func TestDefaultsAreSafe(t *testing.T) {
	c := Defaults()
	if err := c.Validate(); err != nil {
		t.Fatalf("defaults must be valid: %v", err)
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
