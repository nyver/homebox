// Package backup creates and restores ciphertext-only HomeBox server backups.
package backup

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/homebox/homebox/internal/serveridentity"
	_ "modernc.org/sqlite"
)

const (
	manifestName    = "manifest.json"
	manifestVersion = 1
)

// Manifest describes every immutable input to a restore. It deliberately
// carries only hashes and paths: no client plaintext or E2EE private key can
// be part of a server backup.
type Manifest struct {
	Version   int        `json:"version"`
	CreatedAt time.Time  `json:"createdAt"`
	Files     []FileInfo `json:"files"`
}

type FileInfo struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// Create writes an atomic backup directory. destination must not exist, and
// it must not be inside storagePath so a backup cannot recursively copy
// itself. SQLite is snapshotted with VACUUM INTO, which creates a consistent
// database image while a server continues to use WAL mode.
func Create(ctx context.Context, db *sql.DB, storagePath, configPath, destination string) error {
	if db == nil {
		return errors.New("database is required")
	}
	storagePath, destination, err := distinctPaths(storagePath, destination, false)
	if err != nil {
		return err
	}
	if configPath == "" {
		return errors.New("configuration path is required")
	}
	if _, err := os.Stat(filepath.Join(storagePath, "keys", "server_identity.key")); err != nil {
		return fmt.Errorf("read server identity key: %w", err)
	}
	if _, err := os.Stat(configPath); err != nil {
		return fmt.Errorf("read configuration: %w", err)
	}
	if _, err := os.Stat(destination); err == nil {
		return fmt.Errorf("backup destination already exists: %s", destination)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect backup destination: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		return fmt.Errorf("create backup parent directory: %w", err)
	}
	staging, err := os.MkdirTemp(filepath.Dir(destination), ".homebox-backup-")
	if err != nil {
		return fmt.Errorf("create backup staging directory: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(staging)
		}
	}()

	if err := os.MkdirAll(filepath.Join(staging, "database"), 0o700); err != nil {
		return err
	}
	databasePath := filepath.Join(staging, "database", "homebox.db")
	if _, err := db.ExecContext(ctx, "VACUUM INTO "+sqliteLiteral(databasePath)); err != nil {
		return fmt.Errorf("create SQLite snapshot: %w", err)
	}

	databaseInfo, err := hashRegularFile(databasePath)
	if err != nil {
		return fmt.Errorf("hash SQLite snapshot: %w", err)
	}
	databaseInfo.Path = "database/homebox.db"
	files := []FileInfo{databaseInfo}
	for _, relativePath := range []string{
		filepath.Join("keys", "server_identity.key"),
		"config.yaml",
	} {
		var source string
		switch relativePath {
		case "config.yaml":
			source = configPath
		default:
			source = filepath.Join(storagePath, relativePath)
		}
		info, err := copyRegularFile(source, filepath.Join(staging, relativePath), filepath.ToSlash(relativePath))
		if err != nil {
			return err
		}
		files = append(files, info)
	}

	blobs, err := os.ReadDir(filepath.Join(storagePath, "blobs"))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("read ciphertext blobs: %w", err)
	}
	for _, entry := range blobs {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".hbxblob") {
			continue
		}
		relativePath := filepath.Join("blobs", entry.Name())
		info, err := copyRegularFile(filepath.Join(storagePath, relativePath), filepath.Join(staging, relativePath), filepath.ToSlash(relativePath))
		if err != nil {
			return err
		}
		files = append(files, info)
	}

	manifest := Manifest{Version: manifestVersion, CreatedAt: time.Now().UTC(), Files: files}
	if err := writeManifest(filepath.Join(staging, manifestName), manifest); err != nil {
		return err
	}
	if err := verify(staging, manifest); err != nil {
		return fmt.Errorf("verify newly created backup: %w", err)
	}
	if err := os.Rename(staging, destination); err != nil {
		return fmt.Errorf("commit backup: %w", err)
	}
	committed = true
	return nil
}

// Restore validates a backup before writing anything, restores it through a
// sibling staging directory, then atomically moves it into an absent target.
// Requiring an absent target prevents an accidental overwrite of a live
// server's data; stop the server and move its old storage aside explicitly
// before a disaster recovery restore.
func Restore(ctx context.Context, source, storagePath string) error {
	storagePath, source, err := distinctPaths(storagePath, source, true)
	if err != nil {
		return err
	}
	if _, err := os.Stat(storagePath); err == nil {
		return fmt.Errorf("restore target already exists: %s", storagePath)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect restore target: %w", err)
	}
	manifest, err := readManifest(filepath.Join(source, manifestName))
	if err != nil {
		return err
	}
	if err := verify(source, manifest); err != nil {
		return fmt.Errorf("verify backup: %w", err)
	}
	if err := os.MkdirAll(filepath.Dir(storagePath), 0o700); err != nil {
		return fmt.Errorf("create restore parent directory: %w", err)
	}
	staging, err := os.MkdirTemp(filepath.Dir(storagePath), ".homebox-restore-")
	if err != nil {
		return fmt.Errorf("create restore staging directory: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = os.RemoveAll(staging)
		}
	}()
	for _, file := range manifest.Files {
		if file.Path == "config.yaml" {
			continue
		}
		if _, err := copyRegularFile(filepath.Join(source, filepath.FromSlash(file.Path)), filepath.Join(staging, filepath.FromSlash(file.Path)), file.Path); err != nil {
			return err
		}
	}
	if err := verifyStorage(ctx, staging); err != nil {
		return fmt.Errorf("verify restored storage: %w", err)
	}
	if err := os.Rename(staging, storagePath); err != nil {
		return fmt.Errorf("commit restore: %w", err)
	}
	committed = true
	return nil
}

func distinctPaths(storagePath, otherPath string, otherIsSource bool) (string, string, error) {
	storagePath, err := filepath.Abs(storagePath)
	if err != nil {
		return "", "", fmt.Errorf("resolve storage path: %w", err)
	}
	otherPath, err = filepath.Abs(otherPath)
	if err != nil {
		return "", "", fmt.Errorf("resolve backup path: %w", err)
	}
	if storagePath == otherPath || pathWithin(otherPath, storagePath) || (otherIsSource && pathWithin(storagePath, otherPath)) {
		return "", "", errors.New("backup and storage paths must not contain one another")
	}
	return storagePath, otherPath, nil
}

func pathWithin(path, parent string) bool {
	relative, err := filepath.Rel(parent, path)
	return err == nil && relative != "." && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator))
}

func sqliteLiteral(path string) string { return "'" + strings.ReplaceAll(path, "'", "''") + "'" }

func writeManifest(path string, manifest Manifest) error {
	encoded, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return fmt.Errorf("encode backup manifest: %w", err)
	}
	encoded = append(encoded, '\n')
	if err := os.WriteFile(path, encoded, 0o600); err != nil {
		return fmt.Errorf("write backup manifest: %w", err)
	}
	return nil
}

func readManifest(path string) (Manifest, error) {
	encoded, err := os.ReadFile(path)
	if err != nil {
		return Manifest{}, fmt.Errorf("read backup manifest: %w", err)
	}
	var manifest Manifest
	if err := json.Unmarshal(encoded, &manifest); err != nil {
		return Manifest{}, fmt.Errorf("parse backup manifest: %w", err)
	}
	if manifest.Version != manifestVersion || manifest.CreatedAt.IsZero() || len(manifest.Files) < 3 {
		return Manifest{}, errors.New("backup manifest has an unsupported or incomplete format")
	}
	return manifest, nil
}

func verify(root string, manifest Manifest) error {
	seen := make(map[string]struct{}, len(manifest.Files))
	for _, expected := range manifest.Files {
		if !safeManifestPath(expected.Path) {
			return fmt.Errorf("unsafe manifest path %q", expected.Path)
		}
		if _, duplicate := seen[expected.Path]; duplicate {
			return fmt.Errorf("duplicate manifest path %q", expected.Path)
		}
		seen[expected.Path] = struct{}{}
		info, err := hashRegularFile(filepath.Join(root, filepath.FromSlash(expected.Path)))
		if err != nil {
			return err
		}
		if info.Size != expected.Size || info.SHA256 != expected.SHA256 {
			return fmt.Errorf("backup file checksum mismatch: %s", expected.Path)
		}
	}
	for _, required := range []string{"database/homebox.db", "keys/server_identity.key", "config.yaml"} {
		if _, found := seen[required]; !found {
			return fmt.Errorf("backup manifest is missing %s", required)
		}
	}
	return verifyStorage(context.Background(), root)
}

func verifyStorage(ctx context.Context, storagePath string) error {
	if _, err := serveridentity.LoadOrCreate(storagePath); err != nil {
		return fmt.Errorf("validate server identity key: %w", err)
	}
	dbPath := filepath.Join(storagePath, "database", "homebox.db")
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return fmt.Errorf("open SQLite snapshot: %w", err)
	}
	defer db.Close()
	var integrity string
	if err := db.QueryRowContext(ctx, "PRAGMA integrity_check").Scan(&integrity); err != nil {
		return fmt.Errorf("run SQLite integrity check: %w", err)
	}
	if integrity != "ok" {
		return fmt.Errorf("SQLite integrity check failed: %s", integrity)
	}
	foreignKeys, err := db.QueryContext(ctx, "PRAGMA foreign_key_check")
	if err != nil {
		return fmt.Errorf("run SQLite foreign key check: %w", err)
	}
	if foreignKeys.Next() {
		foreignKeys.Close()
		return errors.New("SQLite foreign key check failed")
	}
	if err := foreignKeys.Err(); err != nil {
		foreignKeys.Close()
		return fmt.Errorf("read SQLite foreign key check: %w", err)
	}
	if err := foreignKeys.Close(); err != nil {
		return fmt.Errorf("close SQLite foreign key check: %w", err)
	}
	rows, err := db.QueryContext(ctx, "SELECT storage_rel_path,ciphertext_size,ciphertext_sha256 FROM blobs")
	if err != nil {
		return fmt.Errorf("list blob references: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var relativePath, digest string
		var size int64
		if err := rows.Scan(&relativePath, &size, &digest); err != nil {
			return err
		}
		if !safeBlobPath(relativePath) {
			return fmt.Errorf("unsafe blob reference %q", relativePath)
		}
		info, err := hashRegularFile(filepath.Join(storagePath, filepath.FromSlash(relativePath)))
		if err != nil {
			return fmt.Errorf("verify referenced blob %s: %w", relativePath, err)
		}
		if info.Size != size || info.SHA256 != digest {
			return fmt.Errorf("referenced blob checksum mismatch: %s", relativePath)
		}
	}
	return rows.Err()
}

func safeManifestPath(path string) bool {
	if path == "config.yaml" || path == "database/homebox.db" || path == "keys/server_identity.key" {
		return true
	}
	return safeBlobPath(path)
}

func safeBlobPath(path string) bool {
	if strings.Contains(path, `\`) || !strings.HasPrefix(path, "blobs/") || strings.Count(path, "/") != 1 || !strings.HasSuffix(path, ".hbxblob") {
		return false
	}
	name := strings.TrimSuffix(strings.TrimPrefix(path, "blobs/"), ".hbxblob")
	_, err := uuid.Parse(name)
	return err == nil
}

func copyRegularFile(source, destination, manifestPath string) (FileInfo, error) {
	lstat, err := os.Lstat(source)
	if err != nil {
		return FileInfo{}, fmt.Errorf("inspect backup input %s: %w", manifestPath, err)
	}
	if !lstat.Mode().IsRegular() {
		return FileInfo{}, fmt.Errorf("backup input is not a regular file: %s", manifestPath)
	}
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		return FileInfo{}, fmt.Errorf("create backup directory: %w", err)
	}
	in, err := os.Open(source)
	if err != nil {
		return FileInfo{}, fmt.Errorf("open backup input %s: %w", manifestPath, err)
	}
	defer in.Close()
	out, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return FileInfo{}, fmt.Errorf("create backup output %s: %w", manifestPath, err)
	}
	hash := sha256.New()
	size, copyErr := io.Copy(io.MultiWriter(out, hash), in)
	syncErr := out.Sync()
	closeErr := out.Close()
	if copyErr != nil {
		return FileInfo{}, fmt.Errorf("copy backup input %s: %w", manifestPath, copyErr)
	}
	if syncErr != nil {
		return FileInfo{}, fmt.Errorf("sync backup output %s: %w", manifestPath, syncErr)
	}
	if closeErr != nil {
		return FileInfo{}, fmt.Errorf("close backup output %s: %w", manifestPath, closeErr)
	}
	return FileInfo{Path: manifestPath, Size: size, SHA256: hex.EncodeToString(hash.Sum(nil))}, nil
}

func hashRegularFile(path string) (FileInfo, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return FileInfo{}, err
	}
	if !info.Mode().IsRegular() {
		return FileInfo{}, errors.New("not a regular file")
	}
	f, err := os.Open(path)
	if err != nil {
		return FileInfo{}, err
	}
	defer f.Close()
	hash := sha256.New()
	size, err := io.Copy(hash, f)
	if err != nil {
		return FileInfo{}, err
	}
	return FileInfo{Size: size, SHA256: hex.EncodeToString(hash.Sum(nil))}, nil
}
