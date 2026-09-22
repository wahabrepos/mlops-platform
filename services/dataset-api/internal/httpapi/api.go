// Package httpapi exposes the catalog over HTTP.
//
// Handlers here do one job: decode, call the store, and translate a domain
// error into a status code. No rule lives in this package — if a decision can
// be made differently by calling the endpoints in a different order, it is in
// the wrong layer.
package httpapi

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"

	"github.com/wahabrepos/mlops-platform/services/dataset-api/internal/store"
)

type API struct {
	store   *store.Store
	version string
	metrics *metrics
}

func New(s *store.Store, version string) *API {
	m := newMetrics()
	m.buildVer = version
	return &API{store: s, version: version, metrics: m}
}

// Handler builds the routing table. Go 1.22 patterns carry the method, so a
// wrong method yields 405 rather than a hand-rolled check in every handler.
func (a *API) Handler() http.Handler {
	mux := http.NewServeMux()

	// Liveness must not touch the datastore: see readyz.
	mux.HandleFunc("GET /healthz", a.healthz)
	mux.HandleFunc("GET /readyz", a.readyz)
	mux.HandleFunc("GET /metrics", a.metrics.serve)

	mux.HandleFunc("POST /api/v1/sources", a.createSource)
	mux.HandleFunc("GET /api/v1/sources", a.listSources)

	mux.HandleFunc("POST /api/v1/datasets", a.createDataset)
	mux.HandleFunc("GET /api/v1/datasets/{name}", a.getDataset)

	mux.HandleFunc("POST /api/v1/datasets/{name}/versions", a.createVersion)
	mux.HandleFunc("GET /api/v1/datasets/{name}/versions/{version}", a.getVersion)
	mux.HandleFunc("PUT /api/v1/datasets/{name}/versions/{version}/quality", a.putQuality)
	mux.HandleFunc("POST /api/v1/datasets/{name}/versions/{version}/freeze", a.freeze)
	mux.HandleFunc("GET /api/v1/datasets/{name}/versions/{version}/lineage", a.lineage)

	return a.metrics.middleware(mux)
}

// ---------------------------------------------------------------- plumbing --

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	if v == nil {
		return
	}
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("writing response: %v", err)
	}
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// fail maps a domain error onto a status code. This is the only place that
// mapping exists, so a new caller cannot invent a different one.
func fail(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeErr(w, http.StatusNotFound, err.Error())
	case errors.Is(err, store.ErrConflict):
		writeErr(w, http.StatusConflict, err.Error())
	case errors.Is(err, store.ErrQualityNotPassed):
		// 409, not 403: the request is well-formed and the caller is
		// permitted — the resource is simply not in a state that allows it.
		writeErr(w, http.StatusConflict, "quality has not passed; version cannot be frozen")
	case errors.Is(err, store.ErrFrozen):
		writeErr(w, http.StatusConflict, "version is frozen and cannot be modified")
	default:
		log.Printf("unhandled: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal error")
	}
}

func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		writeErr(w, http.StatusBadRequest, "malformed JSON: "+err.Error())
		return false
	}
	return true
}

// versionNum pulls {version} from the path. A non-numeric segment is a 404,
// not a 400: /versions/banana names a version that does not exist.
func versionNum(w http.ResponseWriter, r *http.Request) (int, bool) {
	n, err := strconv.Atoi(r.PathValue("version"))
	if err != nil {
		writeErr(w, http.StatusNotFound, "no such version")
		return 0, false
	}
	return n, true
}

// ------------------------------------------------------------------ probes --

// healthz answers "is this process alive?" and deliberately does not consult
// the store. Liveness failures get the pod killed; a datastore blip must not.
func (a *API) healthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": a.version})
}

// readyz answers "can this process serve traffic?" and therefore does consult
// the store. Readiness failures pull the pod out of the load balancer and
// leave it running, which is the recoverable outcome.
func (a *API) readyz(w http.ResponseWriter, r *http.Request) {
	if err := a.store.Ready(); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"status": "not ready", "reason": err.Error(),
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// ----------------------------------------------------------------- sources --

func (a *API) createSource(w http.ResponseWriter, r *http.Request) {
	var in store.Source
	if !decode(w, r, &in) {
		return
	}
	if in.URI == "" {
		writeErr(w, http.StatusBadRequest, "uri is required")
		return
	}
	src, err := a.store.CreateSource(in)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, src)
}

func (a *API) listSources(w http.ResponseWriter, r *http.Request) {
	limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
	writeJSON(w, http.StatusOK, map[string]any{"items": a.store.ListSources(limit)})
}

// ---------------------------------------------------------------- datasets --

func (a *API) createDataset(w http.ResponseWriter, r *http.Request) {
	var in store.Dataset
	if !decode(w, r, &in) {
		return
	}
	if in.Name == "" {
		writeErr(w, http.StatusBadRequest, "name is required")
		return
	}
	d, err := a.store.CreateDataset(in)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, d)
}

func (a *API) getDataset(w http.ResponseWriter, r *http.Request) {
	d, err := a.store.GetDataset(r.PathValue("name"))
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, d)
}

// ---------------------------------------------------------------- versions --

func (a *API) createVersion(w http.ResponseWriter, r *http.Request) {
	var in store.NewVersion
	if !decode(w, r, &in) {
		return
	}
	v, err := a.store.CreateVersion(r.PathValue("name"), in)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusCreated, v)
}

func (a *API) getVersion(w http.ResponseWriter, r *http.Request) {
	n, ok := versionNum(w, r)
	if !ok {
		return
	}
	v, err := a.store.GetVersion(r.PathValue("name"), n)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (a *API) putQuality(w http.ResponseWriter, r *http.Request) {
	n, ok := versionNum(w, r)
	if !ok {
		return
	}
	var q store.Quality
	if !decode(w, r, &q) {
		return
	}
	if q.Status != "passed" && q.Status != "failed" {
		writeErr(w, http.StatusBadRequest, `status must be "passed" or "failed"`)
		return
	}
	v, err := a.store.SetQuality(r.PathValue("name"), n, q)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (a *API) freeze(w http.ResponseWriter, r *http.Request) {
	n, ok := versionNum(w, r)
	if !ok {
		return
	}
	v, err := a.store.Freeze(r.PathValue("name"), n)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, v)
}

func (a *API) lineage(w http.ResponseWriter, r *http.Request) {
	n, ok := versionNum(w, r)
	if !ok {
		return
	}
	lin, err := a.store.Lineage(r.PathValue("name"), n)
	if err != nil {
		fail(w, err)
		return
	}
	writeJSON(w, http.StatusOK, lin)
}
