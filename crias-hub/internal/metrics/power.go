package metrics

import (
	"io/fs"
	"math"
	"strings"
	"time"
)

// Device names are kernel inventory entries, not user-provided paths.
func safeDeviceName(name string) bool {
	if len(name) == 0 || len(name) > 128 || name == "." || name == ".." {
		return false
	}
	for _, r := range name {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("_-.:", r)) {
			return false
		}
	}
	return true
}

type Battery struct {
	ID           string
	Present      Sample
	Status       string
	StatusState  Availability
	Capacity     Sample
	Health       Sample
	EnergyNow    Sample
	EnergyFull   Sample
	EnergyDesign Sample
	ChargeNow    Sample
	ChargeFull   Sample
	ChargeDesign Sample
	Voltage      Sample
	Current      Sample
	Power        Sample
	StartLimit   Sample
	EndLimit     Sample
}

type Supply struct {
	ID     string
	Kind   string
	Online Sample
}

type PowerSupplies struct {
	Batteries []Battery
	External  []Supply
	State     Availability
}

func batteryHealth(full, design Sample) Sample {
	source := full.Source + " / " + design.Source
	if !full.Valid() {
		return missing(full.State, Percent, source, full.Scope, full.At)
	}
	if !design.Valid() {
		return missing(design.State, Percent, source, full.Scope, full.At)
	}
	if design.Value <= 0 || full.Unit != design.Unit {
		return missing(Invalid, Percent, source, full.Scope, full.At)
	}
	s := observed(100*full.Value/design.Value, Percent, source, full.Scope, full.At)
	s.State = Estimated
	return s
}

func readBattery(sys fs.FS, dir, id string, at time.Time) Battery {
	scope := "battery " + id
	num := func(name string, unit Unit, divisor, low, high float64) Sample {
		return sysNumber(sys, dir+"/"+name, scope, unit, divisor, low, high, at)
	}
	b := Battery{ID: id, Present: num("present", Boolean, 1, 0, 1)}
	if b.Present.Valid() && b.Present.Value == 0 {
		b.StatusState = Unavailable
		unavailable := func(name string, unit Unit) Sample {
			return missing(Unavailable, unit, "/sys/"+dir+"/"+name, scope, at)
		}
		b.Capacity = unavailable("capacity", Percent)
		b.Health = unavailable("energy_full / energy_full_design", Percent)
		b.EnergyNow, b.EnergyFull, b.EnergyDesign = unavailable("energy_now", WattHours), unavailable("energy_full", WattHours), unavailable("energy_full_design", WattHours)
		b.ChargeNow, b.ChargeFull, b.ChargeDesign = unavailable("charge_now", AmpHours), unavailable("charge_full", AmpHours), unavailable("charge_full_design", AmpHours)
		b.Voltage, b.Current, b.Power = unavailable("voltage_now", Volts), unavailable("current_now", Amps), unavailable("power_now", Watts)
		b.StartLimit, b.EndLimit = unavailable("charge_control_start_threshold", Percent), unavailable("charge_control_end_threshold", Percent)
		return b
	}
	b.Status, b.StatusState = sysText(sys, dir+"/status")
	if b.StatusState == Available {
		switch b.Status {
		case "Charging", "Discharging", "Full", "Not charging", "Unknown":
		default:
			b.Status, b.StatusState = "", Invalid
		}
	}
	b.Capacity = num("capacity", Percent, 1, 0, 100)
	b.EnergyNow = num("energy_now", WattHours, 1e6, 0, 1e6)
	b.EnergyFull = num("energy_full", WattHours, 1e6, 0, 1e6)
	b.EnergyDesign = num("energy_full_design", WattHours, 1e6, 0, 1e6)
	b.ChargeNow = num("charge_now", AmpHours, 1e6, 0, 1e6)
	b.ChargeFull = num("charge_full", AmpHours, 1e6, 0, 1e6)
	b.ChargeDesign = num("charge_full_design", AmpHours, 1e6, 0, 1e6)
	b.Health = batteryHealth(b.EnergyFull, b.EnergyDesign)
	if b.Health.State == Unavailable {
		b.Health = batteryHealth(b.ChargeFull, b.ChargeDesign)
	}
	b.Voltage = num("voltage_now", Volts, 1e6, 0, 1000)
	b.Current = num("current_now", Amps, 1e6, -1000, 1000)
	b.Power = num("power_now", Watts, 1e6, -1e6, 1e6)
	// Do not infer charging direction from current sign. Status is separate.
	// Preserve the driver's signed power, or estimate magnitude from V*I.
	if b.Power.State == Unavailable && b.Voltage.Valid() && b.Current.Valid() {
		b.Power = observed(b.Voltage.Value*math.Abs(b.Current.Value), Watts, b.Voltage.Source+" * abs("+b.Current.Source+")", scope, at)
		b.Power.State = Estimated
	}
	b.StartLimit = num("charge_control_start_threshold", Percent, 1, 0, 100)
	b.EndLimit = num("charge_control_end_threshold", Percent, 1, 0, 100)
	if b.StartLimit.Valid() && b.EndLimit.Valid() && b.StartLimit.Value > b.EndLimit.Value {
		b.StartLimit.State, b.EndLimit.State = Invalid, Invalid
	}
	return b
}

func ReadPowerSupplies(sys fs.FS, at time.Time) PowerSupplies {
	const root = "class/power_supply"
	entries, state := sysEntries(sys, root)
	out := PowerSupplies{State: state}
	if state != Available {
		return out
	}
	for _, e := range entries {
		id := e.Name()
		if !safeDeviceName(id) {
			out.State = Invalid
			continue
		}
		dir := root + "/" + id
		kind, ks := sysText(sys, dir+"/type")
		if ks != Available {
			out.State = ks
			continue
		}
		switch {
		case kind == "Battery":
			out.Batteries = append(out.Batteries, readBattery(sys, dir, id, at))
		case kind == "Mains" || kind == "USB" || strings.HasPrefix(kind, "USB_") || kind == "Wireless":
			scope := "external supply " + id
			out.External = append(out.External, Supply{ID: id, Kind: kind, Online: sysNumber(sys, dir+"/online", scope, Boolean, 1, 0, 1, at)})
		}
	}
	if len(out.Batteries)+len(out.External) == 0 && out.State == Available {
		out.State = Unavailable
	}
	return out
}

type PowerDomain struct {
	ID          string
	Name        string
	NameState   Availability
	Energy      Sample
	EnergyRange Sample
	Instant     Sample
	Average     Sample
}

type PowerDomains struct {
	Values []PowerDomain
	State  Availability
}

type powerBaseline struct {
	name   string
	energy Sample
	rangeJ Sample
}

// PowerCollector uses only flat powercap class entries, avoiding aliases
// from recursive traversal. Never sum parent and child energy domains.
type PowerCollector struct {
	previous map[string]powerBaseline
}

func (c *PowerCollector) Read(sys fs.FS, at time.Time) PowerDomains {
	const root = "class/powercap"
	entries, state := sysEntries(sys, root)
	out := PowerDomains{State: state}
	if state != Available {
		c.previous = nil
		return out
	}
	next := make(map[string]powerBaseline)
	for _, e := range entries {
		id := e.Name()
		if !safeDeviceName(id) || !strings.Contains(id, ":") {
			continue
		}
		dir := root + "/" + id
		name, ns := sysText(sys, dir+"/name")
		scope := "powercap domain " + id
		d := PowerDomain{ID: id, Name: name, NameState: ns}
		d.Energy = sysNumber(sys, dir+"/energy_uj", scope, Joules, 1e6, 0, 1e13, at)
		d.EnergyRange = sysNumber(sys, dir+"/max_energy_range_uj", scope, Joules, 1e6, 0, 1e13, at)
		d.Instant = sysNumber(sys, dir+"/power_uw", scope, Watts, 1e6, 0, 1e6, at)
		d.Average = missing(Waiting, Watts, d.Energy.Source+" delta / elapsed", scope, at)
		if d.EnergyRange.Valid() && (d.EnergyRange.Value <= 0 || d.Energy.Value > d.EnergyRange.Value) {
			d.Energy.State, d.EnergyRange.State = Invalid, Invalid
		}
		switch {
		case ns != Available:
			d.Average.State = ns
		case !d.Energy.Valid():
			d.Average.State = d.Energy.State
		default:
			if prev, ok := c.previous[id]; ok {
				elapsed := at.Sub(prev.energy.At).Seconds()
				if prev.name != name || prev.rangeJ.State != d.EnergyRange.State || prev.rangeJ.Value != d.EnergyRange.Value || elapsed <= 0 || d.Energy.Value < prev.energy.Value {
					// A decrement may be a wrap, reset or hotplug. Without
					// reliable continuity, discard instead of inventing watts.
					d.Average.State = Invalid
				} else if elapsed > 12 {
					d.Average.State = Stale
				} else {
					watts := (d.Energy.Value - prev.energy.Value) / elapsed
					if watts > 1e6 {
						d.Average.State = Invalid
					} else {
						d.Average.Value, d.Average.State = watts, Available
					}
				}
			}
			next[id] = powerBaseline{name: name, energy: d.Energy, rangeJ: d.EnergyRange}
		}
		out.Values = append(out.Values, d)
	}
	c.previous = next
	if len(out.Values) == 0 {
		out.State = Unavailable
	}
	return out
}
