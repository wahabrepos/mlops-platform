package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestRouting pins the routing contract, including the two failure modes that
// are easy to regress: a wrong method and an unknown path.
func TestRouting(t *testing.T) {
	tests := []struct {
		name       string
		method     string
		path       string
		wantStatus int
	}{
		{"healthz responds", http.MethodGet, "/healthz", http.StatusOK},
		{"wrong method rejected", http.MethodPost, "/healthz", http.StatusMethodNotAllowed},
		{"unknown path is 404", http.MethodGet, "/does-not-exist", http.StatusNotFound},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rec := httptest.NewRecorder()
			newMux().ServeHTTP(rec, httptest.NewRequest(tc.method, tc.path, nil))

			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tc.wantStatus)
			}
		})
	}
}

func TestHealthzBody(t *testing.T) {
	rec := httptest.NewRecorder()
	newMux().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	var got map[string]string
	if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
		t.Fatalf("decoding body: %v", err)
	}

	if got["status"] != "ok" {
		t.Errorf("status = %q, want %q", got["status"], "ok")
	}
	if got["version"] == "" {
		t.Error("version is empty; the build-time variable is not wired up")
	}
}
