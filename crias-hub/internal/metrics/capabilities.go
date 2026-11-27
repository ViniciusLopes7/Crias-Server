package metrics

import "math"

// Capability describes evidence of readable telemetry, never permission
// to write. Counts refer to channels/policies/devices in the named scope.
type Capability struct {
	Name      string
	Group     Availability
	Observed  int
	Estimated int
	Waiting   int
	Denied    int
	Invalid   int
	Stale     int
	Missing   int
}

func (c *Capability) add(s Sample, unit Unit) {
	if c.Group != Available {
		return
	}
	if s.State == Available || s.State == Estimated {
		if s.Unit != unit || math.IsNaN(s.Value) || math.IsInf(s.Value, 0) {
			c.Invalid++
			return
		}
	}
	switch s.State {
	case Available:
		c.Observed++
	case Estimated:
		c.Estimated++
	case Waiting:
		c.Waiting++
	case Permission:
		c.Denied++
	case Invalid:
		c.Invalid++
	case Stale:
		c.Stale++
	default:
		c.Missing++
	}
}

// SummaryEvidence selects one item of evidence per domain. Prefer a usable
// measured value over an estimate, then preserve diagnostic states rather
// than letting an absent alternate source hide a failed primary source.
// The bool identifies selection of the average rather than instantaneous
// reading. The detailed view still exposes both independent readings.
func (d PowerDomain) SummaryEvidence() (sample Sample, average bool) {
	rank := func(s Sample) int {
		switch s.State {
		case Available, Estimated:
			if s.Unit != Watts || math.IsNaN(s.Value) || math.IsInf(s.Value, 0) {
				return 4 // invalid, as Capability.add will classify it
			}
			if s.State == Available {
				return 6
			}
			return 5
		case Invalid:
			return 4
		case Permission:
			return 3
		case Stale:
			return 2
		case Waiting:
			return 1
		default:
			return 0
		}
	}
	sample = d.Instant
	if rank(d.Average) > rank(d.Instant) {
		sample, average = d.Average, true
	}
	if (sample.State == Available || sample.State == Estimated) &&
		(sample.Unit != Watts || math.IsNaN(sample.Value) || math.IsInf(sample.Value, 0)) {
		sample.State = Invalid
	}
	return sample, average
}

// Capabilities derives a bounded inventory from the current snapshot.
// Unavailable groups never expose old data. No new reads or probes occur.
func Capabilities(h HardwareSnapshot) []Capability {
	out := make([]Capability, 0, 12)
	clock := Capability{Name: "Clock CPU hardware", Group: h.Frequencies.State}
	driver := Capability{Name: "Clock CPU driver", Group: h.Frequencies.State}
	for _, p := range h.Frequencies.Data.Policies {
		clock.add(p.Observed, MHz)
		driver.add(p.Requested, MHz)
	}
	out = append(out, clock, driver)
	temp := Capability{Name: "Temperatura hwmon", Group: h.Sensors.State}
	fans := Capability{Name: "Ventoinhas RPM", Group: h.Sensors.State}
	for _, s := range h.Sensors.Data.Values {
		switch s.Value.Unit {
		case Celsius:
			temp.add(s.Value, Celsius)
		case RPM:
			fans.add(s.Value, RPM)
		}
	}
	out = append(out, temp, fans)
	zones := Capability{Name: "Zonas térmicas", Group: h.Thermal.State}
	for _, s := range h.Thermal.Data.Values {
		zones.add(s.Value, Celsius)
	}
	out = append(out, zones)
	power := Capability{Name: "Potência por domínio", Group: h.Domains.State}
	for _, d := range h.Domains.Data.Values {
		sample, _ := d.SummaryEvidence()
		power.add(sample, Watts)
	}
	out = append(out, power)
	bat := Capability{Name: "Carga de bateria", Group: h.Supplies.State}
	batPower := Capability{Name: "Potência da bateria", Group: h.Supplies.State}
	start := Capability{Name: "Limite início carga", Group: h.Supplies.State}
	end := Capability{Name: "Limite fim carga", Group: h.Supplies.State}
	for _, b := range h.Supplies.Data.Batteries {
		if b.Present.Valid() && b.Present.Unit == Boolean && b.Present.Value == 0 {
			continue
		}
		bat.add(b.Capacity, Percent)
		batPower.add(b.Power, Watts)
		start.add(b.StartLimit, Percent)
		end.add(b.EndLimit, Percent)
	}
	out = append(out, bat, batPower, start, end)
	net := Capability{Name: "Rede RX", Group: h.Network.State}
	for _, v := range h.Network.Data.Values {
		net.add(v.ReadRate, BytesRate)
	}
	disk := Capability{Name: "Disco leitura", Group: h.Disk.State}
	for _, v := range h.Disk.Data.Values {
		disk.add(v.ReadRate, BytesRate)
	}
	return append(out, net, disk)
}
