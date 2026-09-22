// Command api serves the dataset catalog HTTP API.
//
// Right now it serves only /healthz. That is deliberate: it makes the build,
// the test target and the container image real before any domain logic exists,
// so every later change lands on something that already works.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

// version is injected at build time by the Makefile:
//
//	go build -ldflags="-X main.version=$(GIT_SHA)"
//
// It defaults to "dev" so `go run` still works without the linker flag.
var version = "dev"

// newMux builds the router. It is a separate function from main so tests can
// exercise the real routing table instead of a hand-made approximation.
func newMux() *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", healthz)
	return mux
}

// healthz reports process liveness. Kubernetes will use this as a liveness
// probe: it answers "is this process still working?", not "are its
// dependencies up?" — that distinction belongs to a readiness probe, added
// when there is a database to be ready for.
func healthz(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]string{
		"status":  "ok",
		"version": version,
	}); err != nil {
		log.Printf("healthz: encode: %v", err)
	}
}

func main() {
	addr := os.Getenv("ADDR")
	if addr == "" {
		addr = ":8080"
	}

	srv := &http.Server{
		Addr:    addr,
		Handler: newMux(),
		// Without this, a client that opens a connection and never sends
		// headers holds a goroutine open indefinitely.
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("dataset-api %s listening on %s", version, addr)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("server: %v", err)
	}
}
