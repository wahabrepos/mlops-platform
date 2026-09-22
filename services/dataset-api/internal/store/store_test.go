package store

import (
	"errors"
	"path/filepath"
	"testing"
	"time"
)

// fixture builds a store with one dataset and one source, which is the
// precondition for almost every interesting assertion below.
func fixture(t *testing.T, snapshot string) (*Store, string) {
	t.Helper()
	s, err := New(snapshot)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if _, err := s.CreateDataset(Dataset{Name: "gate-entry-alpr", Owner: "abdiwahab", PII: "direct"}); err != nil {
		t.Fatalf("CreateDataset: %v", err)
	}
	src, err := s.CreateSource(Source{Kind: "alpr", URI: "s3://raw/day=2026-09-01/cam1.parquet"})
	if err != nil {
		t.Fatalf("CreateSource: %v", err)
	}
	return s, src.ID
}

func TestServerAssignsVersionNumbers(t *testing.T) {
	s, srcID := fixture(t, "")

	for want := 1; want <= 3; want++ {
		v, err := s.CreateVersion("gate-entry-alpr", NewVersion{SourceIDs: []string{srcID}})
		if err != nil {
			t.Fatalf("CreateVersion: %v", err)
		}
		if v.Version != want {
			t.Errorf("version = %d, want %d", v.Version, want)
		}
		if v.Frozen {
			t.Error("a new version must not be born frozen")
		}
	}
}

// The gate. This is the single most important test in the package.
func TestFreezeRequiresQualityPassed(t *testing.T) {
	tests := []struct {
		name    string
		quality *Quality
		wantErr error
	}{
		{"no suite has run", nil, ErrQualityNotPassed},
		{"suite failed", &Quality{Status: "failed", FailedChecks: []string{"null plate"}}, ErrQualityNotPassed},
		{"suite passed", &Quality{Status: "passed"}, nil},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, srcID := fixture(t, "")
			v, err := s.CreateVersion("gate-entry-alpr", NewVersion{SourceIDs: []string{srcID}})
			if err != nil {
				t.Fatalf("CreateVersion: %v", err)
			}
			if tc.quality != nil {
				if _, err := s.SetQuality("gate-entry-alpr", v.Version, *tc.quality); err != nil {
					t.Fatalf("SetQuality: %v", err)
				}
			}

			frozen, err := s.Freeze("gate-entry-alpr", v.Version)
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("Freeze error = %v, want %v", err, tc.wantErr)
			}
			if tc.wantErr == nil {
				if !frozen.Frozen {
					t.Error("Frozen flag not set")
				}
				if frozen.FrozenAt == nil {
					t.Error("FrozenAt not stamped")
				}
			}
		})
	}
}

// "Frozen" is worthless if the evidence behind it can be rewritten.
func TestQualityCannotBeEditedAfterFreeze(t *testing.T) {
	s, srcID := fixture(t, "")
	v, _ := s.CreateVersion("gate-entry-alpr", NewVersion{SourceIDs: []string{srcID}})
	if _, err := s.SetQuality("gate-entry-alpr", v.Version, Quality{Status: "passed"}); err != nil {
		t.Fatalf("SetQuality: %v", err)
	}
	if _, err := s.Freeze("gate-entry-alpr", v.Version); err != nil {
		t.Fatalf("Freeze: %v", err)
	}

	_, err := s.SetQuality("gate-entry-alpr", v.Version, Quality{Status: "failed"})
	if !errors.Is(err, ErrFrozen) {
		t.Fatalf("SetQuality after freeze = %v, want ErrFrozen", err)
	}
}

func TestFreezeIsIdempotent(t *testing.T) {
	s, srcID := fixture(t, "")
	v, _ := s.CreateVersion("gate-entry-alpr", NewVersion{SourceIDs: []string{srcID}})
	s.SetQuality("gate-entry-alpr", v.Version, Quality{Status: "passed"})

	first, err := s.Freeze("gate-entry-alpr", v.Version)
	if err != nil {
		t.Fatalf("first freeze: %v", err)
	}
	second, err := s.Freeze("gate-entry-alpr", v.Version)
	if err != nil {
		t.Fatalf("second freeze must not error: %v", err)
	}
	if !first.FrozenAt.Equal(*second.FrozenAt) {
		t.Error("re-freezing moved FrozenAt; the timestamp must record the first freeze")
	}
}

// Airflow retries tasks. A retried register step must not fork one object
// into two catalog ids.
func TestCreateSourceIsIdempotentOnURI(t *testing.T) {
	s, _ := fixture(t, "")
	const uri = "s3://raw/day=2026-09-02/cam9.parquet"

	a, err := s.CreateSource(Source{Kind: "alpr", URI: uri})
	if err != nil {
		t.Fatalf("first: %v", err)
	}
	b, err := s.CreateSource(Source{Kind: "alpr", URI: uri})
	if err != nil {
		t.Fatalf("second: %v", err)
	}
	if a.ID != b.ID {
		t.Errorf("same URI produced two ids: %s and %s", a.ID, b.ID)
	}
}

func TestCreateDatasetRejectsDuplicate(t *testing.T) {
	s, _ := fixture(t, "")
	if _, err := s.CreateDataset(Dataset{Name: "gate-entry-alpr"}); !errors.Is(err, ErrConflict) {
		t.Fatalf("duplicate dataset = %v, want ErrConflict", err)
	}
}

func TestCreateVersionRejectsUnknownDatasetAndSource(t *testing.T) {
	s, srcID := fixture(t, "")

	if _, err := s.CreateVersion("no-such-dataset", NewVersion{SourceIDs: []string{srcID}}); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown dataset = %v, want ErrNotFound", err)
	}
	if _, err := s.CreateVersion("gate-entry-alpr", NewVersion{SourceIDs: []string{"deadbeef"}}); !errors.Is(err, ErrNotFound) {
		t.Errorf("unknown source = %v, want ErrNotFound", err)
	}
}

// The snapshot is the difference between a restart losing everything and not.
func TestSnapshotRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "catalog.json")
	s, srcID := fixture(t, path)

	v, _ := s.CreateVersion("gate-entry-alpr", NewVersion{SourceIDs: []string{srcID}, RowCount: 4211})
	s.SetQuality("gate-entry-alpr", v.Version, Quality{Status: "passed", ReportURI: "s3://curated/r.html"})
	if _, err := s.Freeze("gate-entry-alpr", v.Version); err != nil {
		t.Fatalf("Freeze: %v", err)
	}

	reloaded, err := New(path)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	got, err := reloaded.GetVersion("gate-entry-alpr", 1)
	if err != nil {
		t.Fatalf("GetVersion after reload: %v", err)
	}
	if !got.Frozen {
		t.Error("frozen state did not survive the snapshot")
	}
	if got.RowCount != 4211 {
		t.Errorf("RowCount = %d, want 4211", got.RowCount)
	}
	if !got.Quality.Passed() {
		t.Error("quality verdict did not survive the snapshot")
	}

	// And the next version continues the sequence rather than restarting at 1.
	next, err := reloaded.CreateVersion("gate-entry-alpr", NewVersion{SourceIDs: []string{srcID}})
	if err != nil {
		t.Fatalf("CreateVersion after reload: %v", err)
	}
	if next.Version != 2 {
		t.Errorf("version after reload = %d, want 2", next.Version)
	}
}

func TestLineageResolvesSources(t *testing.T) {
	s, srcID := fixture(t, "")
	v, _ := s.CreateVersion("gate-entry-alpr", NewVersion{SourceIDs: []string{srcID}, GitCommit: "d1b3abb"})

	lin, err := s.Lineage("gate-entry-alpr", v.Version)
	if err != nil {
		t.Fatalf("Lineage: %v", err)
	}
	if lin.Dataset.PII != "direct" {
		t.Errorf("PII = %q, want direct", lin.Dataset.PII)
	}
	if len(lin.Sources) != 1 || lin.Sources[0].ID != srcID {
		t.Errorf("sources not resolved: %+v", lin.Sources)
	}
	if lin.Version.GitCommit != "d1b3abb" {
		t.Error("git commit missing from lineage")
	}
}

func TestGetVersionOutOfRange(t *testing.T) {
	s, _ := fixture(t, "")
	for _, n := range []int{0, -1, 99} {
		if _, err := s.GetVersion("gate-entry-alpr", n); !errors.Is(err, ErrNotFound) {
			t.Errorf("GetVersion(%d) = %v, want ErrNotFound", n, err)
		}
	}
}

func TestReady(t *testing.T) {
	s, _ := fixture(t, "")
	if err := s.Ready(); err != nil {
		t.Errorf("Ready on a live store = %v, want nil", err)
	}
	if (&Store{now: time.Now}).Ready() == nil {
		t.Error("Ready on an uninitialised store must fail; that is what /readyz reports")
	}
}
