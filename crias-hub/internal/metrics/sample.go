// Package metrics contains read-only, typed host telemetry contracts.
package metrics

import (
	"math"
	"time"
)

type Availability string

const (
	Available   Availability = "available"
	Waiting     Availability = "waiting"
	Unavailable Availability = "unavailable"
	Permission  Availability = "permission"
	Invalid     Availability = "invalid"
	Stale       Availability = "stale"
	Estimated   Availability = "estimated"
)

type Unit string

const (
	Percent   Unit = "%"
	Bytes     Unit = "B"
	MHz       Unit = "MHz"
	Celsius   Unit = "°C"
	RPM       Unit = "rpm"
	Watts     Unit = "W"
	WattHours Unit = "Wh"
	AmpHours  Unit = "Ah"
	Volts     Unit = "V"
	Amps      Unit = "A"
	Joules    Unit = "J"
	Boolean   Unit = "bool"
	BytesRate Unit = "B/s"
)

type Sample struct {
	Value  float64
	Unit   Unit
	Source string
	Scope  string
	At     time.Time
	State  Availability
}

func observed(value float64, unit Unit, source, scope string, at time.Time) Sample {
	return Sample{Value: value, Unit: unit, Source: source, Scope: scope, At: at, State: Available}
}

func missing(state Availability, unit Unit, source, scope string, at time.Time) Sample {
	return Sample{Unit: unit, Source: source, Scope: scope, At: at, State: state}
}

// Valid reports an actual observation, not an estimate or a missing value.
func (s Sample) Valid() bool {
	return s.State == Available && !math.IsNaN(s.Value) && !math.IsInf(s.Value, 0)
}

type Profile uint8

const (
	Balanced Profile = iota
	Economy
	Detailed
)

func (p Profile) Interval(base time.Duration) time.Duration {
	switch p {
	case Economy:
		return base * 3
	case Detailed:
		return base / 2
	default:
		return base
	}
}
