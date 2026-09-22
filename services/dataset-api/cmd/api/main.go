// Command api serves the dataset catalog HTTP API.
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/wahabrepos/mlops-platform/services/dataset-api/internal/httpapi"
	"github.com/wahabrepos/mlops-platform/services/dataset-api/internal/store"
)

// version is injected at build time by the Makefile:
//
//	go build -ldflags="-X main.version=$(GIT_SHA)"
var version = "dev"

func main() {
	addr := envOr("ADDR", ":8080")
	snapshot := os.Getenv("SNAPSHOT_PATH") // empty disables persistence

	st, err := store.New(snapshot)
	if err != nil {
		log.Fatalf("loading catalog: %v", err)
	}
	if snapshot != "" {
		log.Printf("catalog snapshot: %s", snapshot)
	} else {
		log.Print("catalog is in-memory only; set SNAPSHOT_PATH to persist")
	}

	srv := &http.Server{
		Addr:              addr,
		Handler:           httpapi.New(st, version).Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	// Graceful shutdown: Kubernetes sends SIGTERM and then waits. Exiting
	// immediately would cut off requests already in flight; ignoring it
	// entirely means waiting out the grace period before being killed.
	idle := make(chan struct{})
	go func() {
		sig := make(chan os.Signal, 1)
		signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
		<-sig
		log.Print("shutting down")

		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := srv.Shutdown(ctx); err != nil {
			log.Printf("shutdown: %v", err)
		}
		close(idle)
	}()

	log.Printf("dataset-api %s listening on %s", version, addr)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server: %v", err)
	}
	<-idle
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
