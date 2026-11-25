package metrics

import (
	"fmt"
	"strings"
	"testing"
	"testing/fstest"
	"time"
)

func sysFixture(values map[string]string) fstest.MapFS {
	files := make(fstest.MapFS, len(values))
	for path, value := range values {
		files[path] = &fstest.MapFile{Data: []byte(value)}
	}
	return files
}

func TestFrequenciesDistinguishSources(t *testing.T) {
	const dir = "devices/system/cpu/cpufreq/policy0/"
	at := time.Unix(100, 0)
	sys := sysFixture(map[string]string{
		dir + "cpuinfo_cur_freq": "1800000\n",
		dir + "scaling_cur_freq": "2400000\n",
		dir + "scaling_min_freq": "400000\n",
		dir + "scaling_max_freq": "4000000\n",
		dir + "scaling_governor": "schedutil\n",
	})
	got := ReadFrequencies(sys, at)
	if got.State != Available || len(got.Policies) != 1 {
		t.Fatal(got)
	}
	p := got.Policies[0]
	if !p.Observed.Valid() || p.Observed.Value != 1800 || p.Observed.Unit != MHz || p.Observed.At != at ||
		p.Requested.State != Estimated || p.Requested.Value != 2400 || p.Governor != "schedutil" ||
		p.ConfiguredMin.Value != 400 || p.ConfiguredMax.Value != 4000 {
		t.Fatal(p)
	}
	delete(sys, dir+"cpuinfo_cur_freq")
	p = ReadFrequencies(sys, at).Policies[0]
	if p.Observed.State != Unavailable || p.Requested.State != Estimated {
		t.Fatal("driver value used as actual observation", p)
	}
	sys[dir+"scaling_min_freq"] = &fstest.MapFile{Data: []byte("5000000")}
	p = ReadFrequencies(sys, at).Policies[0]
	if p.ConfiguredMin.State != Invalid || p.ConfiguredMax.State != Invalid {
		t.Fatal("inverted limits accepted", p)
	}
}

func TestSensorsUnitsAndFaults(t *testing.T) {
	const a = "class/hwmon/hwmon0/"
	const b = "class/hwmon/hwmon1/"
	const c = "class/hwmon/hwmon2/"
	at := time.Unix(100, 0)
	got := ReadSensors(sysFixture(map[string]string{
		a + "name":        "k10temp\n",
		a + "temp1_input": "42500\n",
		a + "temp1_label": "Tctl\n",
		a + "temp2_input": "50000\n",
		a + "temp2_fault": "1\n",
		a + "fan1_input":  "0\n",
		a + "fan2_input":  "-5\n",
		b + "name":        "unknown\n",
		b + "temp1_input": "45000\n",
		c + "name":        "coretemp\n",
		c + "temp1_input": "not a number\n",
		c + "temp1_label": "\x1b[31m\n",
	}), at)
	if got.State != Available || len(got.Values) != 6 {
		t.Fatal(got)
	}
	values := make(map[string]Sensor)
	for _, v := range got.Values {
		values[v.ID] = v
	}
	v := values["hwmon0/temp1"]
	if v.Label != "Tctl" || v.Value.Value != 42.5 || v.Value.Unit != Celsius || !v.Value.Valid() {
		t.Fatal(v)
	}
	if v := values["hwmon0/fan1"].Value; !v.Valid() || v.Value != 0 || v.Unit != RPM {
		t.Fatal("zero RPM is valid", v)
	}
	for _, id := range []string{"hwmon0/fan2", "hwmon0/temp2", "hwmon2/temp1"} {
		if values[id].Value.State != Invalid {
			t.Fatal("invalid sensor", values[id])
		}
	}
	if values["hwmon1/temp1"].Value.State != Unavailable || values["hwmon2/temp1"].Label != "temp1" {
		t.Fatal("unsupported units or unsafe label", values)
	}
}

func TestSysfsMissingPermissionAndLimits(t *testing.T) {
	at := time.Unix(100, 0)
	if ReadSensors(fstest.MapFS{}, at).State != Unavailable || ReadFrequencies(deniedFS{}, at).State != Permission {
		t.Fatal("missing or denied inventory misclassified")
	}
	sys := sysFixture(map[string]string{"value": strings.Repeat("1", maxSysText+1)})
	if _, state := sysText(sys, "value"); state != Invalid {
		t.Fatal("unbounded attribute")
	}
	for i := range maxSysEntries + 1 {
		sys[fmt.Sprintf("class/hwmon/hwmon%d/name", i)] = &fstest.MapFile{Data: []byte("coretemp")}
	}
	if got := ReadSensors(sys, at); got.State != Invalid || len(got.Values) != 0 {
		t.Fatal("unbounded inventory", got)
	}
}
