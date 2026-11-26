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
		if d.Instant.Valid() && d.Instant.Unit == Watts {
			power.add(d.Instant, Watts)
		} else {
			power.add(d.Average, Watts)
		}
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
