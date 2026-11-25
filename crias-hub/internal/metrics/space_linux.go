package metrics

import (
	"math"
	"syscall"
	"time"
)

type Capacity struct {
	Total     Sample
	Available Sample
	Used      Sample
	Usage     Sample
}

// Space reports a known local filesystem, not a sum of mounts.
func Space(path string, at time.Time) Capacity {
	var st syscall.Statfs_t
	if err := syscall.Statfs(path, &st); err != nil {
		return spaceValues(path, at, 0, 0, 0, 0, readState(err))
	}
	return spaceValues(path, at, st.Blocks, st.Bfree, st.Bavail, st.Bsize, Available)
}

func spaceValues(path string, at time.Time, blocks, free, avail uint64, blockSize int64, state Availability) Capacity {
	const source = "statfs"
	scope := "filesystem " + path
	fail := func(s Availability) Capacity {
		b := missing(s, Bytes, source, scope, at)
		return Capacity{Total: b, Available: b, Used: b, Usage: missing(s, Percent, source, scope, at)}
	}
	if state != Available {
		return fail(state)
	}
	if blockSize <= 0 || blocks == 0 || free > blocks || avail > free || blocks > math.MaxUint64/uint64(blockSize) {
		return fail(Invalid)
	}
	size := uint64(blockSize)
	used := (blocks - free) * size
	available := avail * size
	b := func(n uint64) Sample { return observed(float64(n), Bytes, source, scope, at) }
	out := Capacity{Total: b(blocks * size), Available: b(available), Used: b(used)}
	out.Usage = missing(Unavailable, Percent, source, scope, at)
	if used+available > 0 {
		out.Usage = observed(100*float64(used)/float64(used+available), Percent, source, scope, at)
	}
	return out
}
