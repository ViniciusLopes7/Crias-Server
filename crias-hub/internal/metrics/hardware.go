package metrics

import (
	"context"
	"io/fs"
	"slices"
	"sync"
	"time"
)

const (
	sensorCadence  = 2 * time.Second
	batteryCadence = 10 * time.Second
	spaceCadence   = 30 * time.Second
)

// Reading wraps one bounded inventory observation. State describes the
// collection as a whole; individual samples retain their own states.
// A stale collection is not current, even if its previous samples were valid.
type Reading[T any] struct {
	Data     T
	State    Availability
	At       time.Time
	Interval time.Duration
}

func (r Reading[T]) at(now time.Time) Reading[T] {
	if r.At.IsZero() {
		if r.State == "" {
			r.State = Unavailable
		}
	} else if r.State == Available && now.Sub(r.At) > 2*r.Interval {
		r.State = Stale
	}
	return r
}

type HardwareSnapshot struct {
	Frequencies Reading[Frequencies]
	Sensors     Reading[Sensors]
	Thermal     Reading[Sensors]
	Domains     Reading[PowerDomains]
	Supplies    Reading[PowerSupplies]
	Network     Reading[Transfers]
	Disk        Reading[Transfers]
	Space       Reading[Capacity]
}

// Copies are detached from the engine. Published slices are replaced, never
// edited in place by workers, so cloning after releasing the lock is safe.
func (h HardwareSnapshot) copyAt(now time.Time) HardwareSnapshot {
	h.Frequencies = h.Frequencies.at(now)
	h.Frequencies.Data.Policies = slices.Clone(h.Frequencies.Data.Policies)
	h.Sensors = h.Sensors.at(now)
	h.Sensors.Data.Values = slices.Clone(h.Sensors.Data.Values)
	h.Thermal = h.Thermal.at(now)
	h.Thermal.Data.Values = slices.Clone(h.Thermal.Data.Values)
	h.Domains = h.Domains.at(now)
	h.Domains.Data.Values = slices.Clone(h.Domains.Data.Values)
	h.Supplies = h.Supplies.at(now)
	h.Supplies.Data.Batteries = slices.Clone(h.Supplies.Data.Batteries)
	h.Supplies.Data.External = slices.Clone(h.Supplies.Data.External)
	h.Network = h.Network.at(now)
	h.Network.Data.Values = slices.Clone(h.Network.Data.Values)
	h.Disk = h.Disk.at(now)
	h.Disk.Data.Values = slices.Clone(h.Disk.Data.Values)
	h.Space = h.Space.at(now)
	return h
}

// startReading starts exactly one worker for a group. No queue of reads,
// no subprocess, and no goroutine spawned per tick.
func startReading[T any](ctx context.Context, wg *sync.WaitGroup, e *Engine, base time.Duration, target *Reading[T], read func(time.Time) (T, Availability)) {
	*target = Reading[T]{State: Waiting}
	wg.Add(1)
	go func() {
		defer wg.Done()
		e.loop(ctx, base, func(at time.Time, interval time.Duration) {
			value, state := read(at)
			if ctx.Err() != nil {
				return
			}
			e.mu.Lock()
			*target = Reading[T]{Data: value, State: state, At: at, Interval: interval}
			e.mu.Unlock()
			e.notify()
		})
	}()
}

func (e *Engine) startHardware(ctx context.Context, wg *sync.WaitGroup, proc, sys fs.FS, space func(time.Time) Capacity) {
	h := &e.latest.Hardware
	var power PowerCollector
	var network TransferCollector
	disk := TransferCollector{Disk: true}
	startReading(ctx, wg, e, fastCadence, &h.Frequencies, func(at time.Time) (Frequencies, Availability) {
		v := ReadFrequencies(sys, at)
		return v, v.State
	})
	startReading(ctx, wg, e, sensorCadence, &h.Sensors, func(at time.Time) (Sensors, Availability) {
		v := ReadSensors(sys, at)
		return v, v.State
	})
	startReading(ctx, wg, e, sensorCadence, &h.Thermal, func(at time.Time) (Sensors, Availability) {
		v := ReadThermalZones(sys, at)
		return v, v.State
	})
	startReading(ctx, wg, e, sensorCadence, &h.Domains, func(at time.Time) (PowerDomains, Availability) {
		v := power.Read(sys, at)
		return v, v.State
	})
	startReading(ctx, wg, e, batteryCadence, &h.Supplies, func(at time.Time) (PowerSupplies, Availability) {
		v := ReadPowerSupplies(sys, at)
		return v, v.State
	})
	startReading(ctx, wg, e, sensorCadence, &h.Network, func(at time.Time) (Transfers, Availability) {
		v := network.Read(proc, at)
		return v, v.State
	})
	startReading(ctx, wg, e, sensorCadence, &h.Disk, func(at time.Time) (Transfers, Availability) {
		v := disk.Read(proc, at)
		return v, v.State
	})
	if space != nil {
		startReading(ctx, wg, e, spaceCadence, &h.Space, func(at time.Time) (Capacity, Availability) {
			v := space(at)
			return v, v.Total.State
		})
	}
}
