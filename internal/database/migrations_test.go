package database

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	_ "modernc.org/sqlite"
)

func TestAuthenticatedDeviceKeyMigrationPreservesLegacyEnvelopes(t *testing.T) {
	ctx := context.Background()
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "legacy.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if _, err := db.ExecContext(ctx, `PRAGMA foreign_keys=ON; CREATE TABLE schema_migrations (
		version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL
	)`); err != nil {
		t.Fatal(err)
	}
	for _, migration := range migrations[:7] {
		if _, err := db.ExecContext(ctx, migration.SQL); err != nil {
			t.Fatalf("apply legacy migration %d: %v", migration.Version, err)
		}
		if _, err := db.ExecContext(ctx, `INSERT INTO schema_migrations(version,name,applied_at) VALUES(?,?,?)`,
			migration.Version, migration.Name, time.Now().UTC().Format(time.RFC3339Nano)); err != nil {
			t.Fatal(err)
		}
	}
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(ctx, `INSERT INTO users(id,username,username_norm,password_hash,role,status,created_at,updated_at)
		VALUES('user-1','user','user','hash','USER','ACTIVE',?,?)`, now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO devices(id,user_id,name,platform,e2ee_public_key,e2ee_key_version,created_at,last_seen_at)
		VALUES('device-1','user-1','device','OTHER',X'01',1,?,?)`, now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := db.ExecContext(ctx, `INSERT INTO vault_key_envelopes(id,vault_id,target_user_id,target_device_id,key_version,envelope_ciphertext,created_at)
		VALUES('envelope-1','vault-1','user-1','device-1',1,X'02',?)`, now); err != nil {
		t.Fatal(err)
	}

	if err := Migrate(ctx, db); err != nil {
		t.Fatal(err)
	}
	var ciphertext []byte
	var signatureVersion sql.NullInt64
	if err := db.QueryRowContext(ctx, `SELECT envelope_ciphertext,signature_version FROM vault_key_envelopes WHERE id='envelope-1'`).
		Scan(&ciphertext, &signatureVersion); err != nil {
		t.Fatal(err)
	}
	if len(ciphertext) != 1 || ciphertext[0] != 2 || signatureVersion.Valid {
		t.Fatalf("legacy envelope changed during migration: ciphertext=%x signature=%v", ciphertext, signatureVersion)
	}
}
