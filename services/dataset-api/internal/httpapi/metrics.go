package httpapi

import (
	"fmt"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// Instrumentation is hand-written rather than pulled from client_golang.
// The exposition format is a documented text protocol and the service needs
// three series, so the dependency would cost more than it saves — and knowing
// what the format actually is, is the point of building it.

type key struct {
	method string
	route  string
	code   int
}

type metrics struct {
	mu       sync.Mutex
	count    map[key]int64
	durSum   map[key]float64
	buildVer string
}

func newMetrics() *metrics {
	return &metrics{count: map[key]int64{}, durSum: map[key]float64{}}
}

// statusRecorder captures the code, which the ResponseWriter does not expose.
// Defaulting to 200 matters: a handler that writes a body without calling
// WriteHeader has still returned 200.
type statusRecorder struct {
	http.ResponseWriter
	code int
}

func (s *statusRecorder) WriteHeader(c int) {
	s.code = c
	s.ResponseWriter.WriteHeader(c)
}

func (m *metrics) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}

		next.ServeHTTP(rec, r)

		// ServeMux sets r.Pattern on the matched route. Labelling by pattern
		// rather than by r.URL.Path is what stops /datasets/{name} from
		// minting a new time series per dataset — unbounded label
		// cardinality is the classic way to take Prometheus down.
		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}

		m.mu.Lock()
		k := key{r.Method, route, rec.code}
		m.count[k]++
		m.durSum[k] += time.Since(start).Seconds()
		m.mu.Unlock()
	})
}

func (m *metrics) serve(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	keys := make([]key, 0, len(m.count))
	for k := range m.count {
		keys = append(keys, k)
	}
	counts, sums := make(map[key]int64, len(m.count)), make(map[key]float64, len(m.durSum))
	for k, v := range m.count {
		counts[k] = v
	}
	for k, v := range m.durSum {
		sums[k] = v
	}
	ver := m.buildVer
	m.mu.Unlock()

	sort.Slice(keys, func(i, j int) bool {
		if keys[i].route != keys[j].route {
			return keys[i].route < keys[j].route
		}
		if keys[i].method != keys[j].method {
			return keys[i].method < keys[j].method
		}
		return keys[i].code < keys[j].code
	})

	var b strings.Builder
	b.WriteString("# HELP dataset_api_build_info Build information.\n")
	b.WriteString("# TYPE dataset_api_build_info gauge\n")
	fmt.Fprintf(&b, "dataset_api_build_info{version=%q} 1\n", ver)

	b.WriteString("# HELP dataset_api_http_requests_total Requests by method, route and status.\n")
	b.WriteString("# TYPE dataset_api_http_requests_total counter\n")
	for _, k := range keys {
		fmt.Fprintf(&b, "dataset_api_http_requests_total{method=%q,route=%q,code=\"%d\"} %d\n",
			k.method, k.route, k.code, counts[k])
	}

	b.WriteString("# HELP dataset_api_http_request_duration_seconds_sum Cumulative request duration.\n")
	b.WriteString("# TYPE dataset_api_http_request_duration_seconds_sum counter\n")
	for _, k := range keys {
		fmt.Fprintf(&b, "dataset_api_http_request_duration_seconds_sum{method=%q,route=%q,code=\"%d\"} %g\n",
			k.method, k.route, k.code, sums[k])
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(b.String()))
}
