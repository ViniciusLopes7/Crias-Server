package metrics

import (
	"io/fs"
	"time"
)

func ReadThermalZones(sys fs.FS, at time.Time) Sensors {
	const root = "class/thermal"
	entries, state := sysEntries(sys, root)
	out := Sensors{State: state}
	if state != Available {
		return out
	}
	for _, e := range entries {
		id := e.Name()
		if !numbered(id, "thermal_zone", "") {
			continue
		}
		dir := root + "/" + id
		label, ls := sysText(sys, dir+"/type")
		if ls != Available {
			label = id
		}
		v := sysNumber(sys, dir+"/temp", "thermal zone "+id, Celsius, 1000, -273.15, 1000, at)
		out.Values = append(out.Values, Sensor{ID: id, Driver: "thermal", Label: label, Value: v})
	}
	if len(out.Values) == 0 {
		out.State = Unavailable
	}
	return out
}
