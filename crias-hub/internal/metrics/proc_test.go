package metrics

import (
	"io/fs"
	"math"
	"strings"
	"testing"
	"testing/fstest"
	"time"
)

func fixture(name, data string) fstest.MapFS {
	return fstest.MapFS{name: {Data: []byte(data)}}
}

type deniedFS struct{}

func (deniedFS) Open(name string) (fs.File, error) {
	return nil, &fs.PathError{Op: "open", Path: name, Err: fs.ErrPermission}
}

func TestCPUDeltaAndRecovery(t *testing.T) {
	at := time.Unix(100, 0)
	var c CPUCollector
	for _, tc := range []struct {
		text  string
		state Availability
		value float64
	}{
		{"cpu 100 0 20 80 10 0 0 0 50 0\n", Waiting, 0},
		{"cpu 130 0 30 130 20 0 0 0 80 0\n", Available, 40},
		{"cpu 130 0 30 130 20 0 0 0 80 0\n", Waiting, 0},
		{"cpu 1 0 1 2 0 0 0 0\n", Invalid, 0},
		{"cpu 2 0 1 3 0 0 0 0\n", Available, 50},
		{"cpu invalid\n", Invalid, 0},
		{"cpu 3 0 1 4 0 0 0 0\n", Waiting, 0},
	} {
		got := c.Read(fixture("stat", tc.text), at)
		if got.State != tc.state || math.Abs(got.Value-tc.value) > 0.0001 || got.At != at || got.Unit != Percent {
			t.Fatalf("CPU %q: %+v", tc.text, got)
		}
	}
	if got := c.Read(deniedFS{}, at); got.State != Permission {
		t.Fatal(got)
	}
	if got := c.Read(fixture("stat", "cpu 4 0 1 5\n"), at); got.State != Waiting {
		t.Fatal("permission gap bridged", got)
	}
}

func TestCPUInvalidAndBounded(t *testing.T) {
	for _, text := range []string{"cpu 18446744073709551615 1 0 0\n", "cpu 1 2\n", "cpu0 1 2 3 4\n", strings.Repeat("x", maxProcBytes+1)} {
		var c CPUCollector
		if got := c.Read(fixture("stat", text), time.Time{}); got.State != Invalid {
			t.Fatalf("invalid data accepted: %+v", got)
		}
	}
}

func TestMemory(t *testing.T) {
	at := time.Unix(100, 0)
	m := ReadMemory(fixture("meminfo", "MemTotal: 8000 kB\nMemAvailable: 3000 kB\nSwapTotal: 2000 kB\nSwapFree: 500 kB\n"), at)
	if !m.Usage.Valid() || m.Total.Value != 8000*1024 || m.Used.Value != 5000*1024 || m.Usage.Value != 62.5 || m.SwapUsed.Value != 1500*1024 {
		t.Fatalf("memory: %+v", m)
	}
	m = ReadMemory(fixture("meminfo", "MemTotal: 100 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n"), at)
	if m.Usage.State != Unavailable || !m.SwapUsed.Valid() || m.SwapUsed.Value != 0 {
		t.Fatalf("absent MemAvailable or zero swap: %+v", m)
	}
	m = ReadMemory(fixture("meminfo", "MemTotal: 100 kB\nMemAvailable: 101 kB\nSwapTotal: 10 kB\nSwapFree: 11 kB\n"), at)
	if m.Usage.State != Invalid || m.SwapUsed.State != Invalid {
		t.Fatal("invalid ratios accepted")
	}
	for _, data := range []string{"MemTotal: 1 MB\n", "MemTotal: 18446744073709551615 kB\n", "MemTotal: 1 kB\nMemTotal: 2 kB\n"} {
		if got := ReadMemory(fixture("meminfo", data), at); got.Total.State != Invalid {
			t.Fatal("malformed input accepted", got)
		}
	}
	if got := ReadMemory(deniedFS{}, at); got.Usage.State != Permission {
		t.Fatal(got)
	}
}

func TestProfiles(t *testing.T) {
	if Economy.Interval(time.Second) != 3*time.Second || Balanced.Interval(time.Second) != time.Second || Detailed.Interval(time.Second) != time.Second/2 {
		t.Fatal("incorrect profile cadence")
	}
}
