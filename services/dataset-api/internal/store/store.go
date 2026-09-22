// Package store holds the dataset catalog domain and its invariants.
//
// There is no HTTP in this package on purpose. The rules that matter — the
// server assigns version numbers, and a version cannot be frozen until its
// quality suite has passed — are properties of the catalog, not of the
// transport, and they are tested here without a server running.
package store

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var (
	ErrNotFound         = errors.New("not found")
	ErrConflict         = errors.New("already exists")
	ErrQualityNotPassed = errors.New("quality has not passed")
	ErrFrozen           = errors.New("version is frozen")
)

// Source is a raw artifact the platform did not produce: one object in object
// storage, immutable once registered. Nothing here is ever edited.
type Source struct {
	ID           string    `json:"id"`
	Kind         string    `json:"kind"`
	CameraID     string    `json:"camera_id"`
	Site         string    `json:"site"`
	URI          string    `json:"uri"`
	CapturedFrom time.Time `json:"captured_from"`
	CapturedTo   time.Time `json:"captured_to"`
	SizeBytes    int64     `json:"size_bytes"`
	CreatedAt    time.Time `json:"created_at"`
}

// Dataset is a name with an owner and a PII classification. It is deliberately
// not the thing you train on — DatasetVersion is. A dataset is the series; a
// version is the artifact.
type Dataset struct {
	Name          string    `json:"name"`
	Description   string    `json:"description"`
	Owner         string    `json:"owner"`
	PII           string    `json:"pii"`
	RetentionDays int       `json:"retention_days"`
	CreatedAt     time.Time `json:"created_at"`
}

// Quality is the verdict of the expectation suite. Recording it is not the
// same as gating on it: the pipeline records, the store decides.
type Quality struct {
	Status       string    `json:"status"` // "passed" or "failed"
	ReportURI    string    `json:"report_uri"`
	FailedChecks []string  `json:"failed_checks"`
	RecordedAt   time.Time `json:"recorded_at"`
}

// Passed reports whether this verdict permits a freeze. A nil Quality — no
// suite has run — is not a pass.
func (q *Quality) Passed() bool { return q != nil && q.Status == "passed" }

// DatasetVersion is the reproducibility unit: the thing a model cites. Its
// fields together answer "which rows did this model learn from, and what code
// produced them?"
type DatasetVersion struct {
	Dataset    string           `json:"dataset"`
	Version    int              `json:"version"`
	SourceIDs  []string         `json:"source_ids"`
	RowCount   int64            `json:"row_count"`
	Splits     map[string]int64 `json:"splits"`
	StorageURI string           `json:"storage_uri"`
	GitCommit  string           `json:"git_commit"`
	CreatedBy  string           `json:"created_by"`
	CreatedAt  time.Time        `json:"created_at"`
	Quality    *Quality         `json:"quality,omitempty"`
	Frozen     bool             `json:"frozen"`
	FrozenAt   *time.Time       `json:"frozen_at,omitempty"`
}

// NewVersion carries the caller-supplied half of a version. Version is absent
// by design: the server assigns it.
type NewVersion struct {
	SourceIDs  []string         `json:"source_ids"`
	RowCount   int64            `json:"row_count"`
	Splits     map[string]int64 `json:"splits"`
	StorageURI string           `json:"storage_uri"`
	GitCommit  string           `json:"git_commit"`
	CreatedBy  string           `json:"created_by"`
}

// Lineage is the provenance answer: a version, the dataset it belongs to, and
// the resolved source artifacts it was built from.
type Lineage struct {
	Dataset *Dataset        `json:"dataset"`
	Version *DatasetVersion `json:"version"`
	Sources []*Source       `json:"sources"`
}

// state is the serialisable form of the catalog. Keeping it separate from
// Store means the snapshot format does not depend on the mutex or the path.
type state struct {
	Sources  map[string]*Source           `json:"sources"`
	Datasets map[string]*Dataset          `json:"datasets"`
	Versions map[string][]*DatasetVersion `json:"versions"`
}

// Store is an in-memory catalog that snapshots to a JSON file.
//
// In-memory is the right first answer and the wrong last one: it is correct,
// it is fast to test, and it loses every write the moment two replicas exist.
// Postgres replaces it; the interface here does not change when it does.
type Store struct {
	mu           sync.RWMutex
	snapshotPath string
	st           state
	now          func() time.Time // injectable so tests are not timing-dependent
}

// New loads the catalog from snapshotPath if it exists. An empty path disables
// persistence entirely, which is what the tests use.
func New(snapshotPath string) (*Store, error) {
	s := &Store{
		snapshotPath: snapshotPath,
		now:          time.Now,
		st: state{
			Sources:  map[string]*Source{},
			Datasets: map[string]*Dataset{},
			Versions: map[string][]*DatasetVersion{},
		},
	}
	if snapshotPath == "" {
		return s, nil
	}
	b, err := os.ReadFile(snapshotPath)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil // first run
	}
	if err != nil {
		return nil, fmt.Errorf("reading snapshot: %w", err)
	}
	if err := json.Unmarshal(b, &s.st); err != nil {
		return nil, fmt.Errorf("parsing snapshot %s: %w", snapshotPath, err)
	}
	return s, nil
}

// save writes the snapshot atomically: a partial write during a crash would
// otherwise leave a corrupt catalog that fails to load on restart.
// Callers must hold the write lock.
func (s *Store) save() error {
	if s.snapshotPath == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(s.snapshotPath), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(s.st, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.snapshotPath + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, s.snapshotPath)
}

func newID() string {
	b := make([]byte, 12)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
	return hex.EncodeToString(b)
}

// CreateSource registers a raw artifact. It is idempotent on URI: registering
// the same object twice returns the original.
//
// That is not politeness — Airflow retries tasks. A retried register step must
// not fork the catalog into two ids for one object.
func (s *Store) CreateSource(in Source) (*Source, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	for _, existing := range s.st.Sources {
		if existing.URI == in.URI {
			return existing, nil
		}
	}
	in.ID = newID()
	in.CreatedAt = s.now().UTC()
	s.st.Sources[in.ID] = &in
	return &in, s.save()
}

// ListSources returns sources in no guaranteed order. limit <= 0 means all.
func (s *Store) ListSources(limit int) []*Source {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]*Source, 0, len(s.st.Sources))
	for _, src := range s.st.Sources {
		if limit > 0 && len(out) >= limit {
			break
		}
		out = append(out, src)
	}
	return out
}

func (s *Store) CreateDataset(in Dataset) (*Dataset, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, ok := s.st.Datasets[in.Name]; ok {
		return nil, ErrConflict
	}
	in.CreatedAt = s.now().UTC()
	s.st.Datasets[in.Name] = &in
	return &in, s.save()
}

func (s *Store) GetDataset(name string) (*Dataset, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	d, ok := s.st.Datasets[name]
	if !ok {
		return nil, ErrNotFound
	}
	return d, nil
}

// CreateVersion cuts a new version. The number is assigned here, from the
// count of versions already held, and never taken from the caller: two
// concurrent clients each proposing "version 4" is a silent overwrite, and a
// client that has not seen version 3 cannot know what comes next.
func (s *Store) CreateVersion(dataset string, in NewVersion) (*DatasetVersion, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, ok := s.st.Datasets[dataset]; !ok {
		return nil, ErrNotFound
	}
	for _, id := range in.SourceIDs {
		if _, ok := s.st.Sources[id]; !ok {
			return nil, fmt.Errorf("%w: source %s", ErrNotFound, id)
		}
	}

	v := &DatasetVersion{
		Dataset:    dataset,
		Version:    len(s.st.Versions[dataset]) + 1,
		SourceIDs:  in.SourceIDs,
		RowCount:   in.RowCount,
		Splits:     in.Splits,
		StorageURI: in.StorageURI,
		GitCommit:  in.GitCommit,
		CreatedBy:  in.CreatedBy,
		CreatedAt:  s.now().UTC(),
	}
	s.st.Versions[dataset] = append(s.st.Versions[dataset], v)
	return v, s.save()
}

// version returns the stored pointer. Callers must hold at least the read lock.
func (s *Store) version(dataset string, n int) (*DatasetVersion, error) {
	vs := s.st.Versions[dataset]
	if n < 1 || n > len(vs) {
		return nil, ErrNotFound
	}
	return vs[n-1], nil
}

func (s *Store) GetVersion(dataset string, n int) (*DatasetVersion, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.version(dataset, n)
}

// SetQuality records the verdict of the expectation suite. It refuses to touch
// a frozen version: "frozen" would mean nothing if the evidence behind the
// freeze could be rewritten afterwards.
func (s *Store) SetQuality(dataset string, n int, q Quality) (*DatasetVersion, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	v, err := s.version(dataset, n)
	if err != nil {
		return nil, err
	}
	if v.Frozen {
		return nil, ErrFrozen
	}
	q.RecordedAt = s.now().UTC()
	v.Quality = &q
	return v, s.save()
}

// Freeze marks a version immutable. This is the gate: it is one branch, in the
// store, so no client can talk its way around it by calling the endpoints in a
// different order.
func (s *Store) Freeze(dataset string, n int) (*DatasetVersion, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	v, err := s.version(dataset, n)
	if err != nil {
		return nil, err
	}
	if v.Frozen {
		return v, nil // freezing twice is not an error; the state is what was asked for
	}
	if !v.Quality.Passed() {
		return nil, ErrQualityNotPassed
	}
	at := s.now().UTC()
	v.Frozen, v.FrozenAt = true, &at
	return v, s.save()
}

// Lineage resolves a version's source ids into the artifacts themselves.
func (s *Store) Lineage(dataset string, n int) (*Lineage, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	d, ok := s.st.Datasets[dataset]
	if !ok {
		return nil, ErrNotFound
	}
	v, err := s.version(dataset, n)
	if err != nil {
		return nil, err
	}
	srcs := make([]*Source, 0, len(v.SourceIDs))
	for _, id := range v.SourceIDs {
		if src, ok := s.st.Sources[id]; ok {
			srcs = append(srcs, src)
		}
	}
	return &Lineage{Dataset: d, Version: v, Sources: srcs}, nil
}

// Ready reports whether the datastore is usable. This is what /readyz asks and
// what /healthz must not.
func (s *Store) Ready() error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.st.Datasets == nil || s.st.Sources == nil || s.st.Versions == nil {
		return errors.New("catalog not initialised")
	}
	return nil
}
