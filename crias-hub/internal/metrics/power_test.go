package metrics

import (
	"testing"
	"testing/fstest"
	"time"
)

func TestBatterySeparateChargeEnergyAndPower(t *testing.T) {
	const dir = "class/power_supply/BAT0/"
	sys := sysFixture(map[string]string{
		dir + "type":                           "Battery",
		dir + "present":                        "1",
		dir + "status":                         "Discharging",
		dir + "capacity":                       "75",
		dir + "energy_now":                     "30000000",
		dir + "energy_full":                    "40000000",
		dir + "energy_full_design":             "50000000",
		dir + "charge_full":                    "4000000",
		dir + "charge_full_design":             "5000000",
		dir + "voltage_now":                    "12000000",
		dir + "current_now":                    "-1000000",
		dir + "charge_control_start_threshold": "60",
		dir + "charge_control_end_threshold":   "80",
		"class/power_supply/AC/type":           "Mains",
		"class/power_supply/AC/online":         "0",
	})
	at := time.Unix(100, 0)
	got := ReadPowerSupplies(sys, at)
	if got.State != Available || len(got.Batteries) != 1 || len(got.External) != 1 {
		t.Fatal(got)
	}
	b := got.Batteries[0]
	if b.Capacity.Value != 75 || b.EnergyNow.Value != 30 || b.EnergyNow.Unit != WattHours ||
		b.ChargeFull.Value != 4 || b.ChargeFull.Unit != AmpHours || b.Health.State != Estimated ||
		b.Health.Value != 80 || b.Power.State != Estimated || b.Power.Value != 12 ||
		b.Status != "Discharging" || b.EndLimit.Value != 80 || !got.External[0].Online.Valid() || got.External[0].Online.Value != 0 {
		t.Fatal(got)
	}
	sys[dir+"power_now"] = &fstest.MapFile{Data: []byte("-10000000")}
	b = ReadPowerSupplies(sys, at).Batteries[0]
	if !b.Power.Valid() || b.Power.Value != -10 {
		t.Fatal("direct power lost", b.Power)
	}
	delete(sys, dir+"energy_full")
	delete(sys, dir+"energy_full_design")
	b = ReadPowerSupplies(sys, at).Batteries[0]
	if b.Health.State != Estimated || b.Health.Value != 80 {
		t.Fatal("charge-based health unavailable", b.Health)
	}
	sys[dir+"present"] = &fstest.MapFile{Data: []byte("0")}
	b = ReadPowerSupplies(sys, at).Batteries[0]
	if b.Capacity.State != Unavailable || b.Power.State != Unavailable || b.Present.Value != 0 {
		t.Fatal("absent battery exposed cached readings", b)
	}
}

func TestBatteryInvalidAndUnavailable(t *testing.T) {
	const dir = "class/power_supply/BAT0/"
	at := time.Unix(100, 0)
	if ReadPowerSupplies(fstest.MapFS{}, at).State != Unavailable || ReadPowerSupplies(deniedFS{}, at).State != Permission {
		t.Fatal("missing power supply or permission")
	}
	b := ReadPowerSupplies(sysFixture(map[string]string{
		dir + "type":                           "Battery",
		dir + "capacity":                       "101",
		dir + "power_now":                      "broken",
		dir + "voltage_now":                    "12000000",
		dir + "current_now":                    "1000000",
		dir + "energy_full":                    "40000000",
		dir + "energy_full_design":             "0",
		dir + "charge_control_start_threshold": "90",
		dir + "charge_control_end_threshold":   "80",
	}), at).Batteries[0]
	if b.Capacity.State != Invalid || b.Power.State != Invalid || b.Health.State != Invalid ||
		b.StartLimit.State != Invalid || b.EndLimit.State != Invalid || b.StatusState != Unavailable {
		t.Fatal(b)
	}
}

func TestPowerDomainsDeltasAndGaps(t *testing.T) {
	const dir = "class/powercap/intel-rapl:0/"
	const child = "class/powercap/intel-rapl:0:0/"
	sys := sysFixture(map[string]string{
		dir + "name":                "package-0",
		dir + "energy_uj":           "100000000",
		dir + "max_energy_range_uj": "1000000000",
		child + "name":              "core",
		child + "power_uw":          "10000000",
	})
	var c PowerCollector
	at := time.Unix(100, 0)
	out := c.Read(sys, at)
	if len(out.Values) != 2 || out.Values[0].Average.State != Waiting || out.Values[0].Instant.State != Unavailable ||
		out.Values[1].Instant.Value != 10 || out.Values[1].Average.State != Unavailable {
		t.Fatal(out)
	}
	sys[dir+"energy_uj"] = &fstest.MapFile{Data: []byte("140000000")}
	out = c.Read(sys, at.Add(2*time.Second))
	if !out.Values[0].Average.Valid() || out.Values[0].Average.Value != 20 || out.Values[0].Energy.Value != 140 {
		t.Fatal("incorrect domain power", out)
	}
	sys[dir+"energy_uj"] = &fstest.MapFile{Data: []byte("1000000")}
	out = c.Read(sys, at.Add(4*time.Second))
	if out.Values[0].Average.State != Invalid {
		t.Fatal("counter regression assumed wrap", out)
	}
	out = c.Read(sys, at.Add(30*time.Second))
	if out.Values[0].Average.State != Stale {
		t.Fatal("long gap treated as regular interval", out)
	}
	c.Read(deniedFS{}, at.Add(31*time.Second))
	out = c.Read(sys, at.Add(32*time.Second))
	if out.Values[0].Average.State != Waiting {
		t.Fatal("permission gap bridged", out)
	}
}
