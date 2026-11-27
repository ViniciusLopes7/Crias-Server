package metrics

import (
	"sort"
	"time"
)

// At the fastest approved cadence (500 ms), 7200 observations cover an
// hour. Retention also uses timestamps so slower profiles never retain
// more than an hour. Only CPU and RAM usage are allocated initially.
const historyCapacity = 7200
const retention = time.Hour

type point struct {
	at       time.Time
	interval time.Duration
	value    float64
	valid    bool
}

type history struct {
	points [historyCapacity]point
	start  int
	size   int
}

func (h *history) add(s Sample, interval time.Duration) {
	if h.size > 0 {
		last := h.points[(h.start+h.size-1)%historyCapacity]
		if !s.At.After(last.at) {
			return
		}
	}
	cutoff := s.At.Add(-retention)
	for h.size > 0 && !h.points[h.start].at.After(cutoff) {
		h.start = (h.start + 1) % historyCapacity
		h.size--
	}
	if h.size == historyCapacity {
		h.start = (h.start + 1) % historyCapacity
		h.size--
	}
	h.points[(h.start+h.size)%historyCapacity] = point{s.At, interval, s.Value, s.Valid()}
	h.size++
}

type Stats struct {
	Count   int
	Missing int
	Min     float64
	Mean    float64
	Max     float64
	First   time.Time
	Last    time.Time
	Gap     bool
}

// summarize never invents data between observations. Mean is per valid
// sample (not time-weighted). First/Last delimit observed coverage.
func (h *history) summarize(now time.Time, window time.Duration) Stats {
	var s Stats
	if window != time.Minute && window != 5*time.Minute && window != 15*time.Minute && window != retention {
		return s
	}
	cutoff := now.Add(-window)
	// Logical ring order is strictly increasing (add rejects older points).
	// Seek the first point inside the open lower bound, then scan only
	// the requested window in the original chronological order.
	first := sort.Search(h.size, func(i int) bool {
		return h.points[(h.start+i)%historyCapacity].at.After(cutoff)
	})
	var prev point
	for i := first; i < h.size; i++ {
		p := h.points[(h.start+i)%historyCapacity]
		if p.at.After(now) {
			break
		}
		if s.First.IsZero() {
			s.First = p.at
		} else if p.at.Sub(prev.at) > 2*max(prev.interval, p.interval) {
			s.Gap = true
		}
		s.Last, prev = p.at, p
		if !p.valid {
			s.Missing++
			s.Gap = true
			continue
		}
		s.Count++
		if s.Count == 1 {
			s.Min, s.Max, s.Mean = p.value, p.value, p.value
		} else {
			s.Min = min(s.Min, p.value)
			s.Max = max(s.Max, p.value)
			s.Mean += (p.value - s.Mean) / float64(s.Count)
		}
	}
	if s.Last.IsZero() || now.Sub(s.Last) > 2*prev.interval {
		s.Gap = true
	}
	return s
}
