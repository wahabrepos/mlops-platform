package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/wahabrepos/mlops-platform/services/dataset-api/internal/store"
)

func newTestAPI(t *testing.T) http.Handler {
	t.Helper()
	s, err := store.New("")
	if err != nil {
		t.Fatalf("store.New: %v", err)
	}
	return New(s, "test").Handler()
}

func do(t *testing.T, h http.Handler, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var r *http.Request
	if body == nil {
		r = httptest.NewRequest(method, path, nil)
	} else {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		r = httptest.NewRequest(method, path, bytes.NewReader(b))
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, r)
	return rec
}

// seed walks the same path the Airflow DAG walks, up to but not including the
// freeze. Returns the assigned version number.
func seed(t *testing.T, h http.Handler) int {
	t.Helper()

	if c := do(t, h, "POST", "/api/v1/datasets", map[string]any{
		"name": "gate-entry-alpr", "owner": "abdiwahab", "pii": "direct",
	}).Code; c != http.StatusCreated {
		t.Fatalf("create dataset: %d", c)
	}

	rec := do(t, h, "POST", "/api/v1/sources", map[string]any{
		"kind": "alpr", "uri": "s3://raw/day=2026-09-01/cam1.parquet",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create source: %d", rec.Code)
	}
	var src struct {
		ID string `json:"id"`
	}
	json.Unmarshal(rec.Body.Bytes(), &src)

	rec = do(t, h, "POST", "/api/v1/datasets/gate-entry-alpr/versions", map[string]any{
		"source_ids": []string{src.ID}, "row_count": 4211,
		"storage_uri": "s3://curated/v1.parquet", "git_commit": "d1b3abb",
	})
	if rec.Code != http.StatusCreated {
		t.Fatalf("create version: %d — %s", rec.Code, rec.Body)
	}
	var v struct {
		Version int `json:"version"`
	}
	json.Unmarshal(rec.Body.Bytes(), &v)
	if v.Version != 1 {
		t.Fatalf("server assigned version %d, want 1", v.Version)
	}
	return v.Version
}

// The gate, at the edge. This is the response the demo script shows.
func TestFreezeReturns409UntilQualityPasses(t *testing.T) {
	tests := []struct {
		name     string
		quality  map[string]any
		wantCode int
	}{
		{"no suite has run", nil, http.StatusConflict},
		{"suite failed", map[string]any{"status": "failed", "failed_checks": []string{"null plate"}}, http.StatusConflict},
		{"suite passed", map[string]any{"status": "passed", "report_uri": "s3://curated/r.html"}, http.StatusOK},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			h := newTestAPI(t)
			n := seed(t, h)

			if tc.quality != nil {
				if c := do(t, h, "PUT", "/api/v1/datasets/gate-entry-alpr/versions/1/quality", tc.quality).Code; c != http.StatusOK {
					t.Fatalf("put quality: %d", c)
				}
			}

			rec := do(t, h, "POST", "/api/v1/datasets/gate-entry-alpr/versions/1/freeze", nil)
			if rec.Code != tc.wantCode {
				t.Fatalf("freeze = %d, want %d (body %s)", rec.Code, tc.wantCode, rec.Body)
			}
			_ = n
		})
	}
}

func TestQualityCannotBeRewrittenAfterFreeze(t *testing.T) {
	h := newTestAPI(t)
	seed(t, h)
	do(t, h, "PUT", "/api/v1/datasets/gate-entry-alpr/versions/1/quality", map[string]any{"status": "passed"})
	do(t, h, "POST", "/api/v1/datasets/gate-entry-alpr/versions/1/freeze", nil)

	rec := do(t, h, "PUT", "/api/v1/datasets/gate-entry-alpr/versions/1/quality", map[string]any{"status": "failed"})
	if rec.Code != http.StatusConflict {
		t.Fatalf("rewrite quality after freeze = %d, want 409", rec.Code)
	}
}

func TestProbes(t *testing.T) {
	h := newTestAPI(t)
	for _, p := range []string{"/healthz", "/readyz"} {
		if c := do(t, h, "GET", p, nil).Code; c != http.StatusOK {
			t.Errorf("%s = %d, want 200", p, c)
		}
	}
}

func TestRoutingFailures(t *testing.T) {
	h := newTestAPI(t)
	tests := []struct {
		name, method, path string
		want               int
	}{
		{"unknown path", "GET", "/nope", http.StatusNotFound},
		{"wrong method on probe", "POST", "/healthz", http.StatusMethodNotAllowed},
		{"unknown dataset", "GET", "/api/v1/datasets/ghost", http.StatusNotFound},
		{"non-numeric version", "GET", "/api/v1/datasets/gate-entry-alpr/versions/banana", http.StatusNotFound},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if c := do(t, h, tc.method, tc.path, nil).Code; c != tc.want {
				t.Errorf("%s %s = %d, want %d", tc.method, tc.path, c, tc.want)
			}
		})
	}
}

func TestValidation(t *testing.T) {
	h := newTestAPI(t)
	seed(t, h)

	t.Run("duplicate dataset is 409", func(t *testing.T) {
		if c := do(t, h, "POST", "/api/v1/datasets", map[string]any{"name": "gate-entry-alpr"}).Code; c != http.StatusConflict {
			t.Errorf("got %d, want 409", c)
		}
	})
	t.Run("malformed JSON is 400", func(t *testing.T) {
		r := httptest.NewRequest("POST", "/api/v1/datasets", strings.NewReader("{not json"))
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("got %d, want 400", rec.Code)
		}
	})
	t.Run("bad quality status is 400", func(t *testing.T) {
		if c := do(t, h, "PUT", "/api/v1/datasets/gate-entry-alpr/versions/1/quality", map[string]any{"status": "maybe"}).Code; c != http.StatusBadRequest {
			t.Errorf("got %d, want 400", c)
		}
	})
	t.Run("version on unknown dataset is 404", func(t *testing.T) {
		if c := do(t, h, "POST", "/api/v1/datasets/ghost/versions", map[string]any{"source_ids": []string{}}).Code; c != http.StatusNotFound {
			t.Errorf("got %d, want 404", c)
		}
	})
}

// The DAG reads {"items": [...]} and matches on "uri", so the envelope is part
// of the contract, not a formatting preference.
func TestListSourcesEnvelope(t *testing.T) {
	h := newTestAPI(t)
	seed(t, h)

	rec := do(t, h, "GET", "/api/v1/sources?limit=1000", nil)
	var got struct {
		Items []struct {
			ID, URI string
		} `json:"items"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(got.Items) != 1 || got.Items[0].URI == "" || got.Items[0].ID == "" {
		t.Fatalf("items = %+v", got.Items)
	}
}

func TestLineage(t *testing.T) {
	h := newTestAPI(t)
	seed(t, h)

	rec := do(t, h, "GET", "/api/v1/datasets/gate-entry-alpr/versions/1/lineage", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("lineage = %d", rec.Code)
	}
	var lin store.Lineage
	if err := json.Unmarshal(rec.Body.Bytes(), &lin); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if lin.Dataset.PII != "direct" || len(lin.Sources) != 1 || lin.Version.GitCommit != "d1b3abb" {
		t.Errorf("incomplete lineage: %+v", lin)
	}
}

// Label cardinality is the way a metrics endpoint takes down Prometheus:
// one series per dataset name would grow without bound.
func TestMetricsLabelsByRouteNotPath(t *testing.T) {
	h := newTestAPI(t)
	seed(t, h)
	do(t, h, "GET", "/api/v1/datasets/gate-entry-alpr", nil)
	do(t, h, "GET", "/api/v1/datasets/another-dataset", nil)

	body := do(t, h, "GET", "/metrics", nil).Body.String()

	if !strings.Contains(body, `dataset_api_build_info{version="test"} 1`) {
		t.Error("build_info missing")
	}
	if !strings.Contains(body, "dataset_api_http_requests_total") {
		t.Error("request counter missing")
	}
	if strings.Contains(body, "gate-entry-alpr") || strings.Contains(body, "another-dataset") {
		t.Error("dataset names leaked into metric labels; cardinality is unbounded")
	}
	if !strings.Contains(body, `route="GET /api/v1/datasets/{name}"`) {
		t.Errorf("expected route pattern label, got:\n%s", body)
	}
}
