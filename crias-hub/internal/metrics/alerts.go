package metrics

import "time"

type ThermalLimits struct {
	Max           Sample
	Critical      Sample
	MaxReset      Sample
	CriticalReset Sample
}

type ThermalAlert string

const (
	ThermalUnknown  ThermalAlert = "unknown"
	ThermalNormal   ThermalAlert = "normal"
	ThermalWarning  ThermalAlert = "warning"
	ThermalCritical ThermalAlert = "critical"
)

// The threshold comes from the driver. A 3 C reset margin is a UI
// anti-flapping policy, not a hardware safety limit. Native hysteresis
// attributes are absolute temperatures, not differences.
const fallbackResetMargin = 3.0

type thermalBand struct {
	limit float64
	reset float64
	valid bool
}

func makeBand(limit, reset Sample) thermalBand {
	if !limit.Valid() || limit.Unit != Celsius || limit.Value <= 0 {
		return thermalBand{}
	}
	b := thermalBand{limit: limit.Value, reset: limit.Value - fallbackResetMargin, valid: true}
	if reset.Valid() && reset.Unit == Celsius && reset.Value < limit.Value {
		b.reset = reset.Value
	}
	return b
}

func (b thermalBand) active(value float64, previous bool) bool {
	return b.valid && (value >= b.limit || previous && value > b.reset)
}

type thermalKey struct {
	id     string
	driver string
	label  string
}

type thermalState struct {
	max, critical       thermalBand
	warning, criticalOn bool
	at                  time.Time
}

// ThermalTracker is owned by the existing hwmon worker. State is replaced
// each observation, bounded by the inventory limit, never by uptime.
type ThermalTracker struct {
	previous map[thermalKey]thermalState
}

func (t *ThermalTracker) Update(s Sensors, at time.Time) Sensors {
	if s.State != Available || len(s.Values) > maxSysEntries {
		t.previous = nil
		return s
	}
	next := make(map[thermalKey]thermalState)
	for i := range s.Values {
		v := &s.Values[i]
		if v.Value.Unit != Celsius {
			continue
		}
		v.Alert = ThermalUnknown
		if !celsiusDriver(v.Driver) || !v.Value.Valid() || !v.Value.At.Equal(at) {
			continue
		}
		maxBand := makeBand(v.Limits.Max, v.Limits.MaxReset)
		critBand := makeBand(v.Limits.Critical, v.Limits.CriticalReset)
		// Preserve a usable critical threshold even when max is inconsistent.
		if maxBand.valid && critBand.valid && maxBand.limit > critBand.limit {
			maxBand = thermalBand{}
		}
		if !maxBand.valid && !critBand.valid {
			continue
		}
		key := thermalKey{id: v.ID, driver: v.Driver, label: v.Label}
		old := t.previous[key]
		elapsed := at.Sub(old.at)
		continuous := !old.at.IsZero() && elapsed > 0 && elapsed <= 12*time.Second
		current := thermalState{max: maxBand, critical: critBand, at: at}
		current.warning = maxBand.active(v.Value.Value, continuous && old.max == maxBand && old.warning)
		current.criticalOn = critBand.active(v.Value.Value, continuous && old.critical == critBand && old.criticalOn)
		switch {
		case current.criticalOn:
			v.Alert = ThermalCritical
		case current.warning:
			v.Alert = ThermalWarning
		default:
			v.Alert = ThermalNormal
		}
		next[key] = current
	}
	t.previous = next
	return s
}
