package config

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"

	"gopkg.in/yaml.v3"
)

const (
	defaultMaxPlaintextSize   int64 = 500 * 1024 * 1024
	defaultChunkPlaintextSize int64 = 4 * 1024 * 1024
	// Each encrypted chunk has a small AEAD framing overhead. This cap leaves headroom
	// while still bounding server-side ciphertext storage independently of plaintext.
	defaultMaxCiphertextSize int64 = defaultMaxPlaintextSize + ((defaultMaxPlaintextSize / defaultChunkPlaintextSize) * 16)
)

type Config struct {
	Server struct {
		Host        string `yaml:"host"`
		Port        int    `yaml:"port"`
		ReadTimeout string `yaml:"read_timeout"`
		TLS         struct {
			Enabled  bool   `yaml:"enabled"`
			CertFile string `yaml:"cert_file"`
			KeyFile  string `yaml:"key_file"`
		} `yaml:"tls"`
	} `yaml:"server"`
	Storage struct {
		Path           string `yaml:"path"`
		CiphertextOnly bool   `yaml:"ciphertext_only"`
	} `yaml:"storage"`
	Limits struct {
		MaxUsers                 int   `yaml:"max_users"`
		MaxPlaintextFileSize     int64 `yaml:"max_plaintext_file_size_bytes"`
		UploadChunkPlaintextSize int64 `yaml:"upload_chunk_plaintext_size_bytes"`
		MaxCiphertextFileSize    int64 `yaml:"max_ciphertext_file_size_bytes"`
	} `yaml:"limits"`
	Security struct {
		// ApplicationEncryption configures the Secure Transport layer that
		// protects login/tokens/control traffic (ADR-008): TLS 1.3 with a
		// self-signed certificate pinned by its fingerprint instead of a
		// certificate authority. SessionMaxAge is the access-token lifetime;
		// a session past this age must present its refresh token instead.
		ApplicationEncryption struct {
			Enabled         bool   `yaml:"enabled"`
			RequiredForHTTP bool   `yaml:"required_for_http"`
			Protocol        string `yaml:"protocol"`
			SessionMaxAge   string `yaml:"session_max_age"`
		} `yaml:"application_encryption"`
		E2EE struct {
			Required                bool `yaml:"required"`
			ServerDecryptionEnabled bool `yaml:"server_decryption_enabled"`
			ProtocolVersion         int  `yaml:"protocol_version"`
		} `yaml:"e2ee"`
	} `yaml:"security"`
	Uploads struct {
		AbandonedAfterHours int `yaml:"abandoned_after_hours"`
	} `yaml:"uploads"`
	Sync struct {
		PageSize    int `yaml:"page_size"`
		MaxPageSize int `yaml:"max_page_size"`
	} `yaml:"sync"`
	Maintenance struct {
		OrphanBlobGraceHours int `yaml:"orphan_blob_grace_hours"`
	} `yaml:"maintenance"`
}

func Defaults() Config {
	var c Config
	c.Server.Host = "0.0.0.0"
	c.Server.Port = 8787
	c.Server.ReadTimeout = "2m"
	c.Storage.Path = "./data"
	c.Storage.CiphertextOnly = true
	c.Limits.MaxUsers = 5
	c.Limits.MaxPlaintextFileSize = defaultMaxPlaintextSize
	c.Limits.UploadChunkPlaintextSize = defaultChunkPlaintextSize
	c.Limits.MaxCiphertextFileSize = defaultMaxCiphertextSize
	c.Security.ApplicationEncryption.Enabled = true
	c.Security.ApplicationEncryption.RequiredForHTTP = true
	c.Security.ApplicationEncryption.Protocol = "tls1.3-ecdsa-p256-cert-pinning"
	c.Security.ApplicationEncryption.SessionMaxAge = "15m"
	c.Security.E2EE.Required = true
	c.Security.E2EE.ProtocolVersion = 1
	c.Uploads.AbandonedAfterHours = 24
	c.Sync.PageSize = 500
	c.Sync.MaxPageSize = 2000
	c.Maintenance.OrphanBlobGraceHours = 168
	return c
}

func Load(path string) (Config, error) {
	c := Defaults()
	if path == "" {
		return c, c.Validate()
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read config: %w", err)
	}
	if err := yaml.Unmarshal(b, &c); err != nil {
		return Config{}, fmt.Errorf("parse config: %w", err)
	}
	if !filepath.IsAbs(c.Storage.Path) {
		c.Storage.Path = filepath.Clean(c.Storage.Path)
	}
	return c, c.Validate()
}

func (c Config) Validate() error {
	if net.ParseIP(c.Server.Host) == nil && c.Server.Host != "localhost" && c.Server.Host != "" {
		return errors.New("server.host must be an IP address or localhost")
	}
	if c.Server.Port < 1 || c.Server.Port > 65535 {
		return errors.New("server.port must be between 1 and 65535")
	}
	readTimeout, err := time.ParseDuration(c.Server.ReadTimeout)
	if err != nil || readTimeout <= 0 {
		return errors.New("server.read_timeout must be a positive duration")
	}
	if c.Storage.Path == "" || !c.Storage.CiphertextOnly {
		return errors.New("storage.ciphertext_only must be true and storage.path must be set")
	}
	if c.Limits.MaxUsers < 1 || c.Limits.MaxUsers > 5 {
		return errors.New("limits.max_users must be between 1 and 5")
	}
	if c.Limits.MaxPlaintextFileSize <= 0 || c.Limits.MaxPlaintextFileSize > defaultMaxPlaintextSize {
		return fmt.Errorf("limits.max_plaintext_file_size_bytes must be between 1 and %d", defaultMaxPlaintextSize)
	}
	if c.Limits.UploadChunkPlaintextSize <= 0 || c.Limits.UploadChunkPlaintextSize > c.Limits.MaxPlaintextFileSize {
		return errors.New("limits.upload_chunk_plaintext_size_bytes must be positive and no larger than the file limit")
	}
	if c.Limits.MaxCiphertextFileSize < c.Limits.MaxPlaintextFileSize || c.Limits.MaxCiphertextFileSize > defaultMaxCiphertextSize {
		return fmt.Errorf("limits.max_ciphertext_file_size_bytes must be between plaintext limit and %d", defaultMaxCiphertextSize)
	}
	if c.Security.E2EE.ServerDecryptionEnabled || !c.Security.E2EE.Required || c.Security.E2EE.ProtocolVersion != 1 {
		return errors.New("E2EE is mandatory, version 1, and server-side decryption is forbidden")
	}
	if !c.Security.ApplicationEncryption.Enabled || !c.Security.ApplicationEncryption.RequiredForHTTP {
		return errors.New("application encryption is mandatory for HTTP")
	}
	if _, err := time.ParseDuration(c.Security.ApplicationEncryption.SessionMaxAge); err != nil {
		return fmt.Errorf("security.application_encryption.session_max_age: %w", err)
	}
	if c.Server.TLS.Enabled && (c.Server.TLS.CertFile == "" || c.Server.TLS.KeyFile == "") {
		return errors.New("TLS certificate and key files are required when TLS is enabled")
	}
	if c.Uploads.AbandonedAfterHours < 1 {
		return errors.New("uploads.abandoned_after_hours must be positive")
	}
	if c.Sync.PageSize < 1 || c.Sync.MaxPageSize < c.Sync.PageSize {
		return errors.New("sync.page_size must be positive and no larger than sync.max_page_size")
	}
	if c.Maintenance.OrphanBlobGraceHours < 1 {
		return errors.New("maintenance.orphan_blob_grace_hours must be positive")
	}
	return nil
}

func (c Config) Address() string { return net.JoinHostPort(c.Server.Host, fmt.Sprint(c.Server.Port)) }

// HTTPReadTimeout bounds the complete request read, including its body.
// Validate guarantees that the configured duration parses and is positive.
func (c Config) HTTPReadTimeout() time.Duration {
	d, _ := time.ParseDuration(c.Server.ReadTimeout)
	return d
}

// AccessTokenTTL returns the configured access-token lifetime. Validate
// already guarantees SessionMaxAge parses, so a config that has passed
// Validate can call this without a second error check.
func (c Config) AccessTokenTTL() time.Duration {
	d, _ := time.ParseDuration(c.Security.ApplicationEncryption.SessionMaxAge)
	return d
}
