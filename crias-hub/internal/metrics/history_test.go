package metrics

import (
	"testing"
	"time"
)

// Reference implementation retained in tests to check exact equivalence.
func (h *history) summarizeLinear(now time.Time, window time.Duration) Stats {
	var s Stats
	if window != time.Minute && window != 5*time.Minute && window != 15*time.Minute && window != retention {
		return s
	}
	cutoff := now.Add(-window)
	var prev point
	for i := 0; i < h.size; i++ {
		p := h.points[(h.start+i)%historyCapacity]
		if !p.at.After(cutoff) || p.at.After(now) {
			continue
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

func filledHistory(n int) *history {
	h := new(history)
	start := time.Unix(10000, 0)
	at := start
	for i := 0; i < n; i++ {
		interval := 500 * time.Millisecond
		if i%17 == 0 {
			interval = time.Second
		}
		at = at.Add(interval)
		if i%29 == 0 {
			h.add(missing(Permission, Percent, "fixture", "host", at), interval)
		} else {
			h.add(observed(float64(i%101), Percent, "fixture", "host", at), interval)
		}
	}
	return h
}

func TestHistoryWindowSeekEquivalence(t *testing.T) {
	for _, n := range []int{0, 1, 120, historyCapacity, historyCapacity + 2000} {
		h := filledHistory(n)
		now := time.Unix(10000, 0)
		if h.size > 0 {
			now = h.points[(h.start+h.size-1)%historyCapacity].at
		}
		for _, offset := range []time.Duration{-2 * time.Hour, -time.Minute, -time.Second, -time.Nanosecond, 0, time.Nanosecond, time.Minute, 2 * time.Hour} {
			for _, window := range []time.Duration{0, time.Minute, 5 * time.Minute, 15 * time.Minute, time.Hour, 2 * time.Hour} {
				at := now.Add(offset)
				if got, want := h.summarize(at, window), h.summarizeLinear(at, window); got != want {
					t.Fatalf("n=%d offset=%v window=%v: got %+v want %+v", n, offset, window, got, want)
				}
			}
		}
	}
}

func BenchmarkHistoryWindow(b *testing.B) {
	h := filledHistory(historyCapacity + 2000)
	now := h.points[(h.start+h.size-1)%historyCapacity].at
	for _, window := range []time.Duration{time.Minute, time.Hour} {
		b.Run(window.String()+"/linear", func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				_ = h.summarizeLinear(now, window)
			}
		})
		b.Run(window.String()+"/seek", func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				_ = h.summarize(now, window)
			}
		})
	}
}
