package metrics

import (
	"io/fs"
	"math"
	"strconv"
	"strings"
	"time"
)

type Transfer struct {
	ID        string
	Read      Sample
	Write     Sample
	ReadRate  Sample
	WriteRate Sample
}

type Transfers struct {
	Values []Transfer
	State  Availability
}

type transferCounters struct {
	read, write uint64
	at          time.Time
}

// TransferCollector is bound to one source for its lifetime. Separate
// instances must be used for network and disk.
type TransferCollector struct {
	Disk     bool
	previous map[string]transferCounters
}

func transferRate(value, before uint64, elapsed time.Duration, have bool, source, scope string, at time.Time) Sample {
	state := Waiting
	switch {
	case !have:
	case elapsed <= 0 || value < before:
		state = Invalid
	case elapsed > 12*time.Second:
		state = Stale
	default:
		return observed(float64(value-before)/elapsed.Seconds(), BytesRate, source, scope, at)
	}
	return missing(state, BytesRate, source, scope, at)
}

func parseTransfer(line string, disk bool) (string, uint64, uint64, bool) {
	if disk {
		f := strings.Fields(line)
		if len(f) < 14 || !safeDeviceName(f[2]) {
			return "", 0, 0, false
		}
		major, e1 := strconv.ParseUint(f[0], 10, 32)
		minor, e2 := strconv.ParseUint(f[1], 10, 32)
		r, e3 := strconv.ParseUint(f[5], 10, 64)
		w, e4 := strconv.ParseUint(f[9], 10, 64)
		if e1 != nil || e2 != nil || e3 != nil || e4 != nil || r > math.MaxUint64/512 || w > math.MaxUint64/512 {
			return "", 0, 0, false
		}
		id := strconv.FormatUint(major, 10) + ":" + strconv.FormatUint(minor, 10) + "/" + f[2]
		return id, r * 512, w * 512, true
	}
	name, fields, ok := strings.Cut(line, ":")
	id := strings.TrimSpace(name)
	f := strings.Fields(fields)
	if !ok || !safeDeviceName(id) || len(f) != 16 {
		return "", 0, 0, false
	}
	r, er := strconv.ParseUint(f[0], 10, 64)
	w, ew := strconv.ParseUint(f[8], 10, 64)
	return id, r, w, er == nil && ew == nil
}

func (c *TransferCollector) Read(proc fs.FS, at time.Time) Transfers {
	path, scopePrefix := "net/dev", "network interface "
	if c.Disk {
		path, scopePrefix = "diskstats", "block device "
	}
	source := "/proc/" + path
	text, state := readProc(proc, path)
	out := Transfers{State: state}
	if state != Available {
		c.previous = nil
		return out
	}
	lines := strings.Split(text, "\n")
	if !c.Disk {
		if len(lines) < 2 || !strings.Contains(lines[0], "Receive") || !strings.Contains(lines[0], "Transmit") {
			c.previous = nil
			return Transfers{State: Invalid}
		}
		lines = lines[2:]
	}
	next := make(map[string]transferCounters)
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		id, r, w, ok := parseTransfer(line, c.Disk)
		if _, duplicate := next[id]; !ok || duplicate || len(next) >= maxSysEntries {
			c.previous = nil
			return Transfers{State: Invalid}
		}
		before, have := c.previous[id]
		scope := scopePrefix + id
		out.Values = append(out.Values, Transfer{
			ID:        id,
			Read:      observed(float64(r), Bytes, source, scope, at),
			Write:     observed(float64(w), Bytes, source, scope, at),
			ReadRate:  transferRate(r, before.read, at.Sub(before.at), have, source, scope, at),
			WriteRate: transferRate(w, before.write, at.Sub(before.at), have, source, scope, at),
		})
		next[id] = transferCounters{r, w, at}
	}
	c.previous = next
	if len(out.Values) == 0 {
		out.State = Unavailable
	}
	return out
}
