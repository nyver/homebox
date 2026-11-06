package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/homebox/homebox/internal/auth"
	"github.com/homebox/homebox/internal/backup"
	"github.com/homebox/homebox/internal/config"
	"github.com/homebox/homebox/internal/database"
	"github.com/homebox/homebox/internal/favorites"
	"github.com/homebox/homebox/internal/httpapi"
	"github.com/homebox/homebox/internal/httpserver"
	"github.com/homebox/homebox/internal/maintenance"
	"github.com/homebox/homebox/internal/nodes"
	"github.com/homebox/homebox/internal/provisioning"
	"github.com/homebox/homebox/internal/recovery"
	"github.com/homebox/homebox/internal/securetransport"
	"github.com/homebox/homebox/internal/serveridentity"
	"github.com/homebox/homebox/internal/sharing"
	syncpkg "github.com/homebox/homebox/internal/sync"
	"github.com/homebox/homebox/internal/uploads"
)

func main() {
	if len(os.Args) < 2 {
		fatal("usage: homebox <server|fingerprint|bootstrap-admin|create-user|backup|restore|maintenance> [options]")
	}
	switch os.Args[1] {
	case "server":
		serve(os.Args[2:])
	case "fingerprint":
		fingerprint(os.Args[2:])
	case "bootstrap-admin":
		bootstrapAdmin(os.Args[2:])
	case "create-user":
		createUser(os.Args[2:])
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
	service, err := maintenance.New(db, c.Storage.Path, maintenancePolicy(c))
	if err != nil {
		fatal("initialize maintenance: %v", err)
	}
	result, err := service.Run(context.Background())
	if err != nil {
		fatal("run maintenance: %v", err)
	}
	fmt.Printf("Maintenance complete: expired uploads=%d, access tokens=%d, refresh tokens=%d, idempotency operations=%d, expired Trash items=%d, pruned file versions=%d, unreferenced blobs=%d, orphan blob files=%d.\n",
		result.ExpiredUploads, result.ExpiredAccessTokens, result.ExpiredRefreshTokens, result.ExpiredOperations, result.ExpiredTrashItems, result.PrunedFileVersions, result.UnreferencedBlobs, result.OrphanBlobFiles)
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
	tlsConfig, servedFingerprint, err := serverTLSConfig(c, identity)
	if err != nil {
		fatal("build secure transport: %v", err)
	}
	log.Printf("HomeBox server identity fingerprint: %s", servedFingerprint)

	authService := auth.New(db, c.Limits.MaxUsers, c.AccessTokenTTL())
	provisioningService := provisioning.New(db)
	nodesService := nodes.New(db)
	syncService := syncpkg.New(db, c.Sync.PageSize, c.Sync.MaxPageSize)
	uploadsService, err := uploads.New(db, c.Storage.Path, c.Limits.MaxCiphertextFileSize, time.Duration(c.Uploads.AbandonedAfterHours)*time.Hour)
	if err != nil {
		fatal("initialize upload storage: %v", err)
	}
	maintenanceService, err := maintenance.New(db, c.Storage.Path, maintenancePolicy(c))
	if err != nil {
		fatal("initialize automatic maintenance: %v", err)
	}
	// SIGINT/SIGTERM (Ctrl+C, `docker stop`) cancel this context: the
	// server stops accepting connections and gives in-flight requests, such
	// as an upload being committed, time to finish before the database is
	// closed.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	maintenanceDone := make(chan struct{})
	go func() {
		defer close(maintenanceDone)
		runAutomaticMaintenance(ctx, maintenanceService, time.Duration(c.Maintenance.IntervalHours)*time.Hour)
	}()
	api := httpapi.New(authService, provisioningService, nodesService, syncService, uploadsService, sharing.New(db), recovery.New(db), favorites.New(db), maintenanceService)
	server := &http.Server{
		Addr:              c.Address(),
		Handler:           httpserver.New(api),
		TLSConfig:         tlsConfig,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       c.HTTPReadTimeout(),
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}
	log.Printf("HomeBox listening on %s", c.Address())

	serveErr := make(chan error, 1)
	go func() {
		// The certificate is already in server.TLSConfig; there is no
		// plaintext fallback in any mode.
		serveErr <- server.ListenAndServeTLS("", "")
	}()

	select {
	case err := <-serveErr:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			stop()
			<-maintenanceDone
			db.Close()
			fatal("serve: %v", err)
		}
	case <-ctx.Done():
		log.Printf("HomeBox shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("HomeBox shutdown did not finish cleanly: %v", err)
		}
	}
	<-maintenanceDone
}

// serverTLSConfig returns the TLS 1.3 configuration the server listens with
// and the fingerprint clients must pin for it. By default (§7.1) the server
// terminates TLS itself with a self-signed certificate tied to its identity
// key (ADR-008/ADR-009). With server.tls enabled it serves the operator's
// certificate instead (§7.2), whose own P-256 key is then what clients pin.
func serverTLSConfig(c config.Config, identity serveridentity.Identity) (*tls.Config, string, error) {
	if c.Server.TLS.Enabled {
		return securetransport.LoadOperatorTLSConfig(c.Server.TLS.CertFile, c.Server.TLS.KeyFile)
	}
	tlsConfig, err := securetransport.BuildTLSConfig(identity)
	if err != nil {
		return nil, "", err
	}
	return tlsConfig, identity.Fingerprint(), nil
}

// shutdownTimeout bounds how long a stopping server waits for in-flight
// requests. It stays below Docker's default 10-second stop grace period.
const shutdownTimeout = 8 * time.Second

func maintenancePolicy(c config.Config) maintenance.Policy {
	return maintenance.Policy{
		OrphanBlobGrace:  time.Duration(c.Maintenance.OrphanBlobGraceHours) * time.Hour,
		TrashRetention:   time.Duration(c.Maintenance.TrashRetentionDays) * 24 * time.Hour,
		MaxFileVersions:  c.Maintenance.MaxFileVersions,
		VersionRetention: time.Duration(c.Maintenance.VersionRetentionDays) * 24 * time.Hour,
	}
}

func runAutomaticMaintenance(ctx context.Context, service *maintenance.Service, interval time.Duration) {
	run := func() {
		result, err := service.Run(ctx)
		if err != nil {
			if ctx.Err() == nil {
				log.Printf("Automatic maintenance failed: %v", err)
			}
			return
		}
		log.Printf("Automatic maintenance complete: expired uploads=%d, access tokens=%d, refresh tokens=%d, idempotency operations=%d, expired Trash items=%d, pruned file versions=%d, unreferenced blobs=%d, orphan blob files=%d",
			result.ExpiredUploads, result.ExpiredAccessTokens, result.ExpiredRefreshTokens, result.ExpiredOperations, result.ExpiredTrashItems, result.PrunedFileVersions, result.UnreferencedBlobs, result.OrphanBlobFiles)
	}
	run()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			run()
		}
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
	if c.Server.TLS.Enabled {
		_, fingerprint, err := securetransport.LoadOperatorTLSConfig(c.Server.TLS.CertFile, c.Server.TLS.KeyFile)
		if err != nil {
			fatal("load operator TLS certificate: %v", err)
		}
		fmt.Fprintln(os.Stderr, "homebox: server.tls is enabled; this is the fingerprint of the operator certificate's key. Renew the certificate with the same key, or clients must verify a new fingerprint.")
		fmt.Println(fingerprint)
		return
	}
	keyPath := serveridentity.KeyPath(c.Storage.Path)
	_, statErr := os.Stat(keyPath)
	identity, err := serveridentity.LoadOrCreate(c.Storage.Path)
	if err != nil {
		fatal("load server identity: %v", err)
	}
	if errors.Is(statErr, os.ErrNotExist) {
		// Expected before the first server start; with a mistyped --config
		// it would silently mint an identity no client has pinned.
		fmt.Fprintln(os.Stderr, "homebox: created a new server identity at", keyPath)
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
	passwordText, err := readPassword(os.Stdin)
	if err != nil {
		fatal("read password: %v", err)
	}
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

func createUser(args []string) {
	fs := flag.NewFlagSet("create-user", flag.ExitOnError)
	configPath := fs.String("config", "config.yaml", "path to YAML configuration")
	username := fs.String("username", "", "family account username")
	passwordStdin := fs.Bool("password-stdin", false, "read the password from standard input")
	if err := fs.Parse(args); err != nil {
		fatal("parse arguments: %v", err)
	}
	if *username == "" || !*passwordStdin {
		fatal("create-user requires --username and --password-stdin")
	}
	c, err := config.Load(*configPath)
	if err != nil {
		fatal("load config: %v", err)
	}
	password, err := readPassword(os.Stdin)
	if err != nil {
		fatal("read password: %v", err)
	}
	db, err := database.Open(c.Storage.Path)
	if err != nil {
		fatal("open database: %v", err)
	}
	defer db.Close()
	user, err := auth.New(db, c.Limits.MaxUsers, c.AccessTokenTTL()).CreateUser(context.Background(), *username, password)
	if err != nil {
		fatal("create user: %v", err)
	}
	fmt.Printf("Family user %q created (id: %s). Share this opaque ID only with trusted family members.\n", user.Username, user.ID)
}

func readPassword(input io.Reader) (string, error) {
	password, err := io.ReadAll(io.LimitReader(input, 1025))
	if err != nil {
		return "", err
	}
	return strings.TrimSuffix(strings.TrimSuffix(string(password), "\n"), "\r"), nil
}

func fatal(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "homebox: "+format+"\n", args...)
	os.Exit(1)
}
