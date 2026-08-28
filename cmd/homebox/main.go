package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/homebox/homebox/internal/auth"
	"github.com/homebox/homebox/internal/backup"
	"github.com/homebox/homebox/internal/config"
	"github.com/homebox/homebox/internal/database"
	"github.com/homebox/homebox/internal/httpapi"
	"github.com/homebox/homebox/internal/httpserver"
	"github.com/homebox/homebox/internal/maintenance"
	"github.com/homebox/homebox/internal/nodes"
	"github.com/homebox/homebox/internal/provisioning"
	"github.com/homebox/homebox/internal/securetransport"
	"github.com/homebox/homebox/internal/serveridentity"
	syncpkg "github.com/homebox/homebox/internal/sync"
	"github.com/homebox/homebox/internal/uploads"
)

func main() {
	if len(os.Args) < 2 {
		fatal("usage: homebox <server|fingerprint|bootstrap-admin|backup|restore|maintenance> [options]")
	}
	switch os.Args[1] {
	case "server":
		serve(os.Args[2:])
	case "fingerprint":
		fingerprint(os.Args[2:])
	case "bootstrap-admin":
		bootstrapAdmin(os.Args[2:])
	case "backup":
		createBackup(os.Args[2:])
	case "restore":
		restoreBackup(os.Args[2:])
	case "maintenance":
		runMaintenance(os.Args[2:])
	default:
		fatal("unknown command %q", os.Args[1])
	}
}

func createBackup(args []string) {
	fs := flag.NewFlagSet("backup", flag.ExitOnError)
	configPath := fs.String("config", "config.yaml", "path to YAML configuration")
	if err := fs.Parse(args); err != nil {
		fatal("parse arguments: %v", err)
	}
	if fs.NArg() != 1 {
		fatal("usage: homebox backup [--config config.yaml] <new-backup-directory>")
	}
	c, err := config.Load(*configPath)
	if err != nil {
		fatal("load config: %v", err)
	}
	for _, required := range []string{
		filepath.Join(c.Storage.Path, "database", "homebox.db"),
		filepath.Join(c.Storage.Path, "keys", "server_identity.key"),
	} {
		if _, err := os.Stat(required); err != nil {
			fatal("inspect storage: %v", err)
		}
	}
	db, err := database.Open(c.Storage.Path)
	if err != nil {
		fatal("open database: %v", err)
	}
	defer db.Close()
	if err := backup.Create(context.Background(), db, c.Storage.Path, *configPath, fs.Arg(0)); err != nil {
		fatal("create backup: %v", err)
	}
	fmt.Printf("Ciphertext-only backup created at %s. Keep Recovery Secrets off the server.\n", fs.Arg(0))
}

func restoreBackup(args []string) {
	fs := flag.NewFlagSet("restore", flag.ExitOnError)
	configPath := fs.String("config", "config.yaml", "path to YAML configuration for the new storage location")
	if err := fs.Parse(args); err != nil {
		fatal("parse arguments: %v", err)
	}
	if fs.NArg() != 1 {
		fatal("usage: homebox restore [--config config.yaml] <backup-directory>")
	}
	c, err := config.Load(*configPath)
	if err != nil {
		fatal("load config: %v", err)
	}
	if err := backup.Restore(context.Background(), fs.Arg(0), c.Storage.Path); err != nil {
		fatal("restore backup: %v", err)
	}
	fmt.Printf("Backup restored to %s. Start the server and verify its pinned fingerprint before reconnecting clients.\n", c.Storage.Path)
}

func runMaintenance(args []string) {
	fs := flag.NewFlagSet("maintenance", flag.ExitOnError)
	configPath := fs.String("config", "config.yaml", "path to YAML configuration")
	if err := fs.Parse(args); err != nil {
		fatal("parse arguments: %v", err)
	}
	if fs.NArg() != 0 {
		fatal("usage: homebox maintenance [--config config.yaml]")
	}
	c, err := config.Load(*configPath)
	if err != nil {
		fatal("load config: %v", err)
	}
	if _, err := os.Stat(filepath.Join(c.Storage.Path, "database", "homebox.db")); err != nil {
		fatal("inspect storage: %v", err)
	}
	db, err := database.Open(c.Storage.Path)
	if err != nil {
		fatal("open database: %v", err)
	}
	defer db.Close()
	service, err := maintenance.New(db, c.Storage.Path, time.Duration(c.Maintenance.OrphanBlobGraceHours)*time.Hour)
	if err != nil {
		fatal("initialize maintenance: %v", err)
	}
	result, err := service.Run(context.Background())
	if err != nil {
		fatal("run maintenance: %v", err)
	}
	fmt.Printf("Maintenance complete: expired uploads=%d, access tokens=%d, refresh tokens=%d, idempotency operations=%d, unreferenced blobs=%d, orphan blob files=%d.\n",
		result.ExpiredUploads, result.ExpiredAccessTokens, result.ExpiredRefreshTokens, result.ExpiredOperations, result.UnreferencedBlobs, result.OrphanBlobFiles)
}

func serve(args []string) {
	fs := flag.NewFlagSet("server", flag.ExitOnError)
	configPath := fs.String("config", "config.yaml", "path to YAML configuration")
	host := fs.String("host", "", "listener host override")
	port := fs.Int("port", 0, "listener port override")
	tlsEnabled := fs.String("tls", "", "enable or disable TLS (true or false)")
	if err := fs.Parse(args); err != nil {
		fatal("parse arguments: %v", err)
	}
	c, err := config.Load(*configPath)
	if err != nil {
		fatal("load config: %v", err)
	}
	if *host != "" {
		c.Server.Host = *host
	}
	if *port != 0 {
		c.Server.Port = *port
	}
	if *tlsEnabled != "" {
		value, parseErr := strconv.ParseBool(*tlsEnabled)
		if parseErr != nil {
			fatal("parse --tls: %v", parseErr)
		}
		c.Server.TLS.Enabled = value
	}
	if err := c.Validate(); err != nil {
		fatal("validate server overrides: %v", err)
	}
	db, err := database.Open(c.Storage.Path)
	if err != nil {
		fatal("open database: %v", err)
	}
	defer db.Close()
	identity, err := serveridentity.LoadOrCreate(c.Storage.Path)
	if err != nil {
		fatal("load server identity: %v", err)
	}
	log.Printf("HomeBox server identity fingerprint: %s", identity.Fingerprint())

	authService := auth.New(db, c.Limits.MaxUsers, c.AccessTokenTTL())
	provisioningService := provisioning.New(db)
	nodesService := nodes.New(db)
	syncService := syncpkg.New(db, c.Sync.PageSize, c.Sync.MaxPageSize)
	uploadsService, err := uploads.New(db, c.Storage.Path, c.Limits.MaxCiphertextFileSize, time.Duration(c.Uploads.AbandonedAfterHours)*time.Hour)
	if err != nil {
		fatal("initialize upload storage: %v", err)
	}
	api := httpapi.New(authService, provisioningService, nodesService, syncService, uploadsService)
	server := &http.Server{Addr: c.Address(), Handler: httpserver.New(api), ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second}
	log.Printf("HomeBox listening on %s", c.Address())

	if c.Server.TLS.Enabled {
		// Operator-supplied certificate (e.g. a direct Let's Encrypt cert
		// without a reverse proxy in front). See §7.2.
		err = server.ListenAndServeTLS(c.Server.TLS.CertFile, c.Server.TLS.KeyFile)
	} else {
		// Default "direct HTTP + custom port" deployment mode (§7.1): the
		// server terminates TLS itself using a self-signed certificate tied
		// to its identity key, trusted by clients via fingerprint pinning
		// rather than a CA (ADR-008/ADR-009). There is no plaintext fallback.
		tlsConfig, tlsErr := securetransport.BuildTLSConfig(identity)
		if tlsErr != nil {
			fatal("build secure transport: %v", tlsErr)
		}
		server.TLSConfig = tlsConfig
		err = server.ListenAndServeTLS("", "")
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		fatal("serve: %v", err)
	}
}

func fingerprint(args []string) {
	fs := flag.NewFlagSet("fingerprint", flag.ExitOnError)
	configPath := fs.String("config", "config.yaml", "path to YAML configuration")
	if err := fs.Parse(args); err != nil {
		fatal("parse arguments: %v", err)
	}
	c, err := config.Load(*configPath)
	if err != nil {
		fatal("load config: %v", err)
	}
	identity, err := serveridentity.LoadOrCreate(c.Storage.Path)
	if err != nil {
		fatal("load server identity: %v", err)
	}
	fmt.Println(identity.Fingerprint())
}

func bootstrapAdmin(args []string) {
	fs := flag.NewFlagSet("bootstrap-admin", flag.ExitOnError)
	configPath := fs.String("config", "config.yaml", "path to YAML configuration")
	username := fs.String("username", "", "admin username")
	passwordStdin := fs.Bool("password-stdin", false, "read the password from standard input")
	if err := fs.Parse(args); err != nil {
		fatal("parse arguments: %v", err)
	}
	if *username == "" || !*passwordStdin {
		fatal("bootstrap-admin requires --username and --password-stdin")
	}
	c, err := config.Load(*configPath)
	if err != nil {
		fatal("load config: %v", err)
	}
	password, err := io.ReadAll(io.LimitReader(os.Stdin, 1025))
	if err != nil {
		fatal("read password: %v", err)
	}
	passwordText := strings.TrimSuffix(strings.TrimSuffix(string(password), "\n"), "\r")
	db, err := database.Open(c.Storage.Path)
	if err != nil {
		fatal("open database: %v", err)
	}
	defer db.Close()
	user, err := auth.New(db, c.Limits.MaxUsers, c.AccessTokenTTL()).BootstrapAdmin(context.Background(), *username, passwordText)
	if err != nil {
		fatal("bootstrap admin: %v", err)
	}
	fmt.Printf("Bootstrap admin %q created (id: %s).\n", user.Username, user.ID)
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "homebox: "+format+"\n", args...)
	os.Exit(1)
}
