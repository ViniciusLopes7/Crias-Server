package metrics

import (
	"io"
	"io/fs"
	"sort"
	"strconv"
	"strings"
	"time"
)

const maxSysEntries = 512
const maxSysText = 4096

func sysEntries(sys fs.FS, dir string) ([]fs.DirEntry, Availability) {
	f, err := sys.Open(dir)
	if err != nil {
		return nil, readState(err)
	}
	defer f.Close()
	d, ok := f.(fs.ReadDirFile)
	if !ok {
		return nil, Invalid
	}
	entries, err := d.ReadDir(maxSysEntries + 1)
	if err != nil && err != io.EOF {
		return nil, readState(err)
	}
	if len(entries) > maxSysEntries {
		return nil, Invalid
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	return entries, Available
}

func sysText(sys fs.FS, name string) (string, Availability) {
	f, err := sys.Open(name)
	if err != nil {
		return "", readState(err)
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, maxSysText+1))
	if err != nil {
		return "", readState(err)
	}
	if len(b) > maxSysText {
		return "", Invalid
	}
	text := strings.TrimSpace(string(b))
	if text == "" {
		return "", Invalid
	}
	// Labels and driver names are later rendered in a terminal. Accept
	// only printable ASCII here, not escape sequences or multiline text.
	for _, r := range text {
		if r < 32 || r > 126 {
			return "", Invalid
		}
	}
	return text, Available
}

func sysNumber(sys fs.FS, path, scope string, unit Unit, divisor, low, high float64, at time.Time) Sample {
	source := "/sys/" + path
	text, state := sysText(sys, path)
	if state != Available {
		return missing(state, unit, source, scope, at)
	}
	n, err := strconv.ParseInt(text, 10, 64)
	v := float64(n) / divisor
	if err != nil || v < low || v > high {
		return missing(Invalid, unit, source, scope, at)
	}
	return observed(v, unit, source, scope, at)
}

func numbered(name, prefix, suffix string) bool {
	if !strings.HasPrefix(name, prefix) || !strings.HasSuffix(name, suffix) || len(name) <= len(prefix)+len(suffix) {
		return false
	}
	for _, r := range name[len(prefix) : len(name)-len(suffix)] {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

type FrequencyPolicy struct {
	ID            string
	Governor      string
	GovernorState Availability
	Observed      Sample
	Requested     Sample
	ConfiguredMin Sample
	ConfiguredMax Sample
}

type Frequencies struct {
	Policies []FrequencyPolicy
	State    Availability
}

// ReadFrequencies reports policies, not individual cores. scaling_cur_freq
// is reported separately as a driver value, never substituted for hardware.
func ReadFrequencies(sys fs.FS, at time.Time) Frequencies {
	const root = "devices/system/cpu/cpufreq"
	entries, state := sysEntries(sys, root)
	result := Frequencies{State: state}
	if state != Available {
		return result
	}
	for _, e := range entries {
		id := e.Name()
		if !numbered(id, "policy", "") {
			continue
		}
		dir := root + "/" + id + "/"
		scope := "CPU policy " + id
		freq := func(name string) Sample {
			// Bounds guard corrupt input, not a hardware tuning policy.
			return sysNumber(sys, dir+name, scope, MHz, 1000, 0, 100000, at)
		}
		governor, gs := sysText(sys, dir+"scaling_governor")
		p := FrequencyPolicy{
			ID: id, Governor: governor, GovernorState: gs,
			Observed: freq("cpuinfo_cur_freq"), Requested: freq("scaling_cur_freq"),
			ConfiguredMin: freq("scaling_min_freq"), ConfiguredMax: freq("scaling_max_freq"),
		}
		if p.Requested.Valid() {
			p.Requested.State = Estimated
		}
		if p.ConfiguredMin.Valid() && p.ConfiguredMax.Valid() && p.ConfiguredMin.Value > p.ConfiguredMax.Value {
			p.ConfiguredMin.State, p.ConfiguredMax.State = Invalid, Invalid
		}
		result.Policies = append(result.Policies, p)
	}
	if len(result.Policies) == 0 {
		result.State = Unavailable
	}
	return result
}

type Sensor struct {
	ID     string
	Driver string
	Label  string
	Value  Sample
	Limits ThermalLimits
	Alert  ThermalAlert
}

type Sensors struct {
	Values []Sensor
	State  Availability
}

// Only documented Celsius drivers are interpreted as temperatures. Other
// hwmon temp inputs can be voltage; do not silently assign a Celsius unit.
func celsiusDriver(driver string) bool {
	switch driver {
	case "coretemp", "k10temp", "acpitz", "amdgpu", "nvme", "dell_smm":
		return true
	default:
		return false
	}
}

func ReadSensors(sys fs.FS, at time.Time) Sensors {
	const root = "class/hwmon"
	devices, state := sysEntries(sys, root)
	result := Sensors{State: state}
	if state != Available {
		return result
	}
	for _, dev := range devices {
		id := dev.Name()
		if !numbered(id, "hwmon", "") {
			continue
		}
		dir := root + "/" + id
		driver, ds := sysText(sys, dir+"/name")
		entries, es := sysEntries(sys, dir)
		if es != Available {
			result.State = es
			continue
		}
		names := make(map[string]bool, len(entries))
		for _, e := range entries {
			names[e.Name()] = true
		}
		for _, e := range entries {
			name := e.Name()
			temp := numbered(name, "temp", "_input")
			fan := numbered(name, "fan", "_input")
			if !temp && !fan {
				continue
			}
			if len(result.Values) >= maxSysEntries {
				result.State = Invalid
				return result
			}
			prefix := strings.TrimSuffix(name, "_input")
			label, ls := sysText(sys, dir+"/"+prefix+"_label")
			if ls != Available {
				label = prefix
			}
			scope := id + "/" + prefix
			if ds == Available {
				scope += " (" + driver + ")"
			}
			path := dir + "/" + name
			var v Sample
			switch {
			case fan:
				v = sysNumber(sys, path, scope, RPM, 1, 0, 1000000, at)
			case ds != Available:
				v = missing(ds, Celsius, "/sys/"+path, scope, at)
			case celsiusDriver(driver):
				v = sysNumber(sys, path, scope, Celsius, 1000, -273.15, 1000, at)
			default:
				v = missing(Unavailable, Celsius, "/sys/"+path, scope, at)
			}
			faultPath := prefix + "_fault"
			if names[faultPath] {
				fault := sysNumber(sys, dir+"/"+faultPath, scope, "", 1, 0, 1, at)
				if !fault.Valid() {
					v.State = fault.State
				} else if fault.Value != 0 {
					v.State = Invalid
				}
			}
			sensor := Sensor{ID: id + "/" + prefix, Driver: driver, Label: label, Value: v}
			if temp && ds == Available && celsiusDriver(driver) {
				limit := func(suffix string) Sample {
					p := dir + "/" + prefix + suffix
					if !names[prefix+suffix] {
						return missing(Unavailable, Celsius, "/sys/"+p, scope, at)
					}
					return sysNumber(sys, p, scope, Celsius, 1000, -273.15, 1000, at)
				}
				sensor.Limits = ThermalLimits{Max: limit("_max"), Critical: limit("_crit"), MaxReset: limit("_max_hyst"), CriticalReset: limit("_crit_hyst")}
			}
			result.Values = append(result.Values, sensor)
		}
	}
	if len(result.Values) == 0 && result.State == Available {
		result.State = Unavailable
	}
	return result
}
