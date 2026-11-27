package metrics

import (
	"testing"
	"time"
)

func TestThermalThresholdsAndHysteresis(t *testing.T) {
	const d = "class/hwmon/hwmon0/"
	sys := sysFixture(map[string]string{
		d + "name":           "coretemp",
		d + "temp1_label":    "Package id 0",
		d + "temp1_input":    "80000",
		d + "temp1_max":      "80000",
		d + "temp1_max_hyst": "75000",
		d + "temp1_crit":     "95000",
	})
	var tracker ThermalTracker
	at := time.Unix(100, 0)
	for _, tc := range []struct {
		input string
		want  ThermalAlert
	}{
		{"79000", ThermalNormal},
		{"80000", ThermalWarning},
		{"78000", ThermalWarning},
		{"75000", ThermalNormal},
		{"95000", ThermalCritical},
		{"93000", ThermalCritical},
		{"92000", ThermalWarning},
		{"75000", ThermalNormal},
	} {
		sys[d+"temp1_input"].Data = []byte(tc.input)
		s := tracker.Update(ReadSensors(sys, at), at)
		if len(s.Values) != 1 || s.Values[0].Alert != tc.want {
			t.Fatal(tc, s)
		}
		at = at.Add(2 * time.Second)
	}
}

func TestThermalUnknownAndReset(t *testing.T) {
	const d = "class/hwmon/hwmon0/"
	sys := sysFixture(map[string]string{
		d + "name":        "k10temp",
		d + "temp1_input": "90000",
		d + "temp1_max":   "80000",
		d + "temp1_fault": "0",
	})
	var tracker ThermalTracker
	at := time.Unix(100, 0)
	read := func() ThermalAlert {
		s := tracker.Update(ReadSensors(sys, at), at)
		at = at.Add(2 * time.Second)
		return s.Values[0].Alert
	}
	if read() != ThermalWarning {
		t.Fatal("threshold missed")
	}
	sys[d+"temp1_fault"].Data = []byte("1")
	if read() != ThermalUnknown {
		t.Fatal("faulty sensor evaluated")
	}
	sys[d+"temp1_fault"].Data = []byte("0")
	sys[d+"temp1_input"].Data = []byte("79000")
	if read() != ThermalNormal {
		t.Fatal("latch survived invalid sample")
	}
	sys[d+"temp1_input"].Data = []byte("90000")
	if read() != ThermalWarning {
		t.Fatal("warning missing")
	}
	at = at.Add(20 * time.Second)
	sys[d+"temp1_input"].Data = []byte("79000")
	if read() != ThermalNormal {
		t.Fatal("latch survived gap")
	}
	delete(sys, d+"temp1_max")
	if read() != ThermalUnknown {
		t.Fatal("invented threshold")
	}
}
