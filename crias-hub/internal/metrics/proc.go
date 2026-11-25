package metrics

import (
	"errors"
	"io"
	"io/fs"
	"math"
	"strconv"
	"strings"
	"time"
)

const maxProcBytes = 1 << 20

// readProc uses an injected filesystem rooted at /proc in production. Reads
// are bounded; fixture tests do not depend on a running Linux host.
func readProc(proc fs.FS, name string) (string, Availability) {
	f, err := proc.Open(name)
	if err != nil {
		return "", readState(err)
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxProcBytes+1))
	if err != nil {
		return "", readState(err)
	}
	if len(b) > maxProcBytes {
		return "", Invalid
	}
	return string(b), Available
}

func readState(err error) Availability {
	if errors.Is(err, fs.ErrPermission) {
		return Permission
	}
	return Unavailable
}

type cpuCounters struct {
	fields [8]uint64
	total  uint64
	idle   uint64
}

func parseCPU(text string) (cpuCounters, bool) {
	for _, line := range strings.Split(text, "\n") {
		fields := strings.Fields(line)
		if len(fields) == 0 || fields[0] != "cpu" {
			continue
		}
		// user, nice, system, idle, iowait, irq, softirq, steal.
		// guest and guest_nice are already included in user/nice.
		if len(fields) < 5 {
			return cpuCounters{}, false
		}
		var c cpuCounters
		for i, token := range fields[1:min(len(fields), 9)] {
			n, err := strconv.ParseUint(token, 10, 64)
			if err != nil || math.MaxUint64-c.total < n {
				return cpuCounters{}, false
			}
			c.fields[i] = n
			c.total += n
			if i == 3 || i == 4 {
				c.idle += n
			}
		}
		return c, true
	}
	return cpuCounters{}, false
}

// CPUCollector owns its preceding observation. One caller at a time;
// scheduling and cancellation will be owned by the C03 sampling engine.
type CPUCollector struct {
	previous cpuCounters
	have     bool
}

func (c *CPUCollector) Read(proc fs.FS, at time.Time) Sample {
	const source, scope = "/proc/stat", "host CPU (aggregate)"
	text, state := readProc(proc, "stat")
	if state != Available {
		c.have = false
		return missing(state, Percent, source, scope, at)
	}
	next, ok := parseCPU(text)
	if !ok {
		c.have = false
		return missing(Invalid, Percent, source, scope, at)
	}
	previous, have := c.previous, c.have
	c.previous, c.have = next, true
	if !have {
		return missing(Waiting, Percent, source, scope, at)
	}
	for i, n := range next.fields {
		if n < previous.fields[i] {
			return missing(Invalid, Percent, source, scope, at)
		}
	}
	if next.total < previous.total || next.idle < previous.idle {
		return missing(Invalid, Percent, source, scope, at)
	}
	total, idle := next.total-previous.total, next.idle-previous.idle
	if idle > total {
		return missing(Invalid, Percent, source, scope, at)
	}
	if total == 0 {
		return missing(Waiting, Percent, source, scope, at)
	}
	return observed(100*float64(total-idle)/float64(total), Percent, source, scope, at)
}

type Memory struct {
	Total     Sample
	Available Sample
	Used      Sample
	Usage     Sample
	SwapTotal Sample
	SwapUsed  Sample
}

func ReadMemory(proc fs.FS, at time.Time) Memory {
	const source, scope = "/proc/meminfo", "host memory"
	fail := func(state Availability) Memory {
		b := missing(state, Bytes, source, scope, at)
		return Memory{Total: b, Available: b, Used: b, Usage: missing(state, Percent, source, scope, at), SwapTotal: b, SwapUsed: b}
	}
	text, state := readProc(proc, "meminfo")
	if state != Available {
		return fail(state)
	}
	values := make(map[string]uint64, 4)
	for _, line := range strings.Split(text, "\n") {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		key := f[0]
		switch key {
		case "MemTotal:", "MemAvailable:", "SwapTotal:", "SwapFree:":
		default:
			continue
		}
		if _, exists := values[key]; exists || len(f) != 3 || f[2] != "kB" {
			return fail(Invalid)
		}
		n, err := strconv.ParseUint(f[1], 10, 64)
		if err != nil || n > math.MaxUint64/1024 {
			return fail(Invalid)
		}
		values[key] = n * 1024
	}
	m := fail(Unavailable)
	total, hasTotal := values["MemTotal:"]
	avail, hasAvail := values["MemAvailable:"]
	swap, hasSwap := values["SwapTotal:"]
	free, hasFree := values["SwapFree:"]
	bytes := func(n uint64) Sample { return observed(float64(n), Bytes, source, scope, at) }
	bad := missing(Invalid, Bytes, source, scope, at)
	if hasTotal {
		if total == 0 {
			m.Total = bad
		} else {
			m.Total = bytes(total)
		}
	}
	if hasAvail && m.Total.Valid() {
		if avail > total {
			m.Available, m.Used = bad, bad
			m.Usage = missing(Invalid, Percent, source, scope, at)
		} else {
			m.Available, m.Used = bytes(avail), bytes(total-avail)
			m.Usage = observed(100*float64(total-avail)/float64(total), Percent, source, scope, at)
		}
	}
	if hasSwap {
		m.SwapTotal = bytes(swap)
		if hasFree {
			if free > swap {
				m.SwapUsed = bad
			} else {
				m.SwapUsed = bytes(swap - free)
			}
		}
	}
	return m
}
