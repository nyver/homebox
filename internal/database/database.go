package database

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite"
)

func Open(storagePath string) (*sql.DB, error) {
	databaseDir := filepath.Join(storagePath, "database")
	if err := os.MkdirAll(databaseDir, 0o700); err != nil {
		return nil, fmt.Errorf("create database directory: %w", err)
	}
	db, err := sql.Open("sqlite", dataSourceName(filepath.Join(databaseDir, "homebox.db")))
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	// WAL lets readers proceed while one writer commits, so a small pool
	// keeps a slow request (or a large sync page) from stalling every other
	// API call behind a single shared connection.
	db.SetMaxOpenConns(maxOpenConns)
	db.SetMaxIdleConns(maxOpenConns)
	if err := db.PingContext(context.Background()); err != nil {
		db.Close()
		return nil, fmt.Errorf("configure database: %w", err)
	}
	if err := Migrate(context.Background(), db); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

const maxOpenConns = 8

// dataSourceName applies the connection settings through the DSN rather
// than a one-off PRAGMA statement: foreign_keys and busy_timeout are
// per-connection, so every pooled connection must receive them. Write
// transactions begin IMMEDIATE so they take SQLite's write lock up front
// and wait in busy_timeout instead of failing with SQLITE_BUSY when a
// deferred read transaction later tries to upgrade to a write.
func dataSourceName(path string) string {
	return path + "?_pragma=busy_timeout(5000)&_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_txlock=immediate"
}

// Migrate applies pending migrations in order inside individual transactions,
// recording each applied version so restarts are idempotent and schema
// evolution never requires deleting an existing database (see AGENTS.md /
// spec §36.4: "migrations обязательны").
func Migrate(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL
	)`); err != nil {
		return fmt.Errorf("create schema_migrations: %w", err)
	}
	applied := map[int]bool{}
	rows, err := db.QueryContext(ctx, "SELECT version FROM schema_migrations")
	if err != nil {
		return fmt.Errorf("read schema_migrations: %w", err)
	}
	for rows.Next() {
		var version int
		if err := rows.Scan(&version); err != nil {
			rows.Close()
			return err
		}
		applied[version] = true
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return err
	}
	rows.Close()

	for _, m := range migrations {
		if applied[m.Version] {
			continue
		}
		tx, err := db.BeginTx(ctx, nil)
		if err != nil {
			return fmt.Errorf("begin migration %d: %w", m.Version, err)
		}
		if _, err := tx.ExecContext(ctx, m.SQL); err != nil {
			tx.Rollback()
			return fmt.Errorf("apply migration %d (%s): %w", m.Version, m.Name, err)
		}
		if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations (version,name,applied_at) VALUES (?,?,?)`,
			m.Version, m.Name, time.Now().UTC().Format(time.RFC3339Nano)); err != nil {
			tx.Rollback()
			return fmt.Errorf("record migration %d: %w", m.Version, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("commit migration %d: %w", m.Version, err)
		}
	}
	return nil
}
