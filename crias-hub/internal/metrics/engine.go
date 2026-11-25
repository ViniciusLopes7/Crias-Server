package metrics

import (
	"context"
	"io/fs"
	"sync"
	"sync/atomic"
	"time"
)

const fastCadence = time.Second

type Snapshot struct {
	CPU      Sample
	Memory   Memory
	Hardware HardwareSnapshot
}

// Engine is session-owned. One worker per independent collector; no
// overlapping invocation, unbounded queue, or timer in the render loop.
type Engine struct {
	mu          sync.RWMutex
	latest      Snapshot
	cpuInterval time.Duration
	memInterval time.Duration
	cpuHistory  history
	memHistory  history
	profile     atomic.Uint32
	changed     chan struct{}
	done        chan struct{}
	cancel      context.CancelFunc
}

func NewEngine(parent context.Context, proc fs.FS) *Engine {
	return newEngine(parent, proc, nil, nil)
}

// NewHostEngine adds the native hardware collectors. The space callback must
// read a known local filesystem, never a path obtained from terminal input.
func NewHostEngine(parent context.Context, proc, sys fs.FS, space func(time.Time) Capacity) *Engine {
	return newEngine(parent, proc, sys, space)
}

func newEngine(parent context.Context, proc, sys fs.FS, space func(time.Time) Capacity) *Engine {
	ctx, cancel := context.WithCancel(parent)
	now := time.Now()
	cpu := missing(Waiting, Percent, "/proc/stat", "host CPU (aggregate)", now)
	b := missing(Waiting, Bytes, "/proc/meminfo", "host memory", now)
	usage := missing(Waiting, Percent, "/proc/meminfo", "host memory", now)
	e := &Engine{
		latest:      Snapshot{CPU: cpu, Memory: Memory{Total: b, Available: b, Used: b, Usage: usage, SwapTotal: b, SwapUsed: b}},
		cpuInterval: fastCadence,
		memInterval: fastCadence,
		changed:     make(chan struct{}, 1),
		done:        make(chan struct{}),
		cancel:      cancel,
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		var c CPUCollector
		e.loop(ctx, fastCadence, func(at time.Time, interval time.Duration) {
			s := c.Read(proc, at)
			if ctx.Err() != nil {
				return
			}
			e.mu.Lock()
			e.latest.CPU, e.cpuInterval = s, interval
			e.cpuHistory.add(s, interval)
			e.mu.Unlock()
			e.notify()
		})
	}()
	go func() {
		defer wg.Done()
		e.loop(ctx, func(at time.Time, interval time.Duration) {
			m := ReadMemory(proc, at)
			if ctx.Err() != nil {
				return
			}
			e.mu.Lock()
			e.latest.Memory, e.memInterval = m, interval
			e.memHistory.add(m.Usage, interval)
			e.mu.Unlock()
			e.notify()
		})
	}()
	if sys != nil {
		e.startHardware(ctx, &wg, proc, sys, space)
	}
	go func() {
		wg.Wait()
		close(e.done)
	}()
	return e
}

// Each interval starts after the previous collection completes. Slow
// reads never create a backlog. Profile changes take effect next cycle.
func (e *Engine) loop(ctx context.Context, base time.Duration, collect func(time.Time, time.Duration)) {
	for ctx.Err() == nil {
		interval := Profile(e.profile.Load()).Interval(base)
		collect(time.Now(), interval)
		if ctx.Err() != nil {
			return
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
		}
	}
}

func (e *Engine) notify() {
	select {
	case e.changed <- struct{}{}:
	default:
	}
}

// Changed coalesces notifications. Consumers read the latest snapshot;
// the channel is intentionally never closed (select Done for shutdown).
func (e *Engine) Changed() <-chan struct{} { return e.changed }
func (e *Engine) Done() <-chan struct{}    { return e.done }

// Stop requests cancellation without waiting on kernel I/O. Done closes
// after workers return. Context alone cannot interrupt a blocked fs.Read.
func (e *Engine) Stop() { e.cancel() }

func (e *Engine) SetProfile(p Profile) bool {
	if p != Economy && p != Balanced && p != Detailed {
		return false
	}
	e.profile.Store(uint32(p))
	return true
}

func fresh(s Sample, now time.Time, interval time.Duration) Sample {
	if (s.State == Available || s.State == Estimated) && now.Sub(s.At) > 2*interval {
		s.State = Stale
	}
	return s
}

func (e *Engine) Snapshot(now time.Time) Snapshot {
	e.mu.RLock()
	s, cpuInterval, memInterval := e.latest, e.cpuInterval, e.memInterval
	e.mu.RUnlock()
	s.Hardware = s.Hardware.copyAt(now)
	s.CPU = fresh(s.CPU, now, cpuInterval)
	m := &s.Memory
	for _, v := range []*Sample{&m.Total, &m.Available, &m.Used, &m.Usage, &m.SwapTotal, &m.SwapUsed} {
		*v = fresh(*v, now, memInterval)
	}
	return s
}

func (e *Engine) History(now time.Time, window time.Duration) (cpu, memory Stats) {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return e.cpuHistory.summarize(now, window), e.memHistory.summarize(now, window)
}
