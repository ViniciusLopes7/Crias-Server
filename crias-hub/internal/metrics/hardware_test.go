package metrics

import (
	"context"
	"testing"
	"time"
)

func TestHostEngineHardwareAndSnapshotIsolation(t *testing.T) {
	proc := sysFixture(map[string]string{
		"stat":      "cpu 1 0 1 2\n",
		"meminfo":   "MemTotal: 100 kB\nMemAvailable: 40 kB\n",
		"net/dev":   "Inter-| Receive | Transmit\n face | bytes | bytes\neth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\n",
		"diskstats": "8 0 sda 0 0 10 0 0 0 20 0 0 0 0\n",
	})
	sys := sysFixture(map[string]string{
		"devices/system/cpu/cpufreq/policy0/scaling_cur_freq": "1800000",
		"class/hwmon/hwmon0/name":                             "coretemp",
		"class/hwmon/hwmon0/temp1_input":                      "42000",
		"class/thermal/thermal_zone0/temp":                    "43000",
		"class/power_supply/AC/type":                          "Mains",
		"class/power_supply/AC/online":                        "1",
		"class/powercap/intel-rapl:0/name":                    "package-0",
		"class/powercap/intel-rapl:0/energy_uj":               "1000000",
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	e := NewHostEngine(ctx, proc, sys, func(at time.Time) Capacity {
		return spaceValues("/", at, 100, 40, 30, 4096, Available)
	})
	defer e.Stop()
	deadline := time.After(3 * time.Second)
	var h HardwareSnapshot
	for {
		h = e.Snapshot(time.Now()).Hardware
		if h.Frequencies.State == Available && h.Sensors.State == Available && h.Thermal.State == Available &&
			h.Domains.State == Available && h.Supplies.State == Available && h.Network.State == Available &&
			h.Disk.State == Available && h.Space.State == Available {
			break
		}
		select {
		case <-e.Changed():
		case <-deadline:
			t.Fatalf("hardware groups not published: %+v", h)
		}
	}
	if h.Frequencies.Interval != time.Second || h.Sensors.Interval != 2*time.Second ||
		h.Supplies.Interval != 10*time.Second || h.Space.Interval != 30*time.Second {
		t.Fatal("incorrect cadences")
	}
	if h.Sensors.Data.Values[0].Value.Value != 42 || h.Thermal.Data.Values[0].Value.Value != 43 {
		t.Fatal("incorrect sensor values")
	}
	h.Sensors.Data.Values[0].Value.Value = 999
	h.Network.Data.Values[0].ID = "mutated"
	h.Supplies.Data.External[0].Online.Value = 0
	next := e.Snapshot(time.Now()).Hardware
	if next.Sensors.Data.Values[0].Value.Value != 42 || next.Network.Data.Values[0].ID != "eth0" ||
		next.Supplies.Data.External[0].Online.Value != 1 {
		t.Fatal("snapshot aliases engine storage")
	}
	stale := e.Snapshot(time.Now().Add(7*time.Second)).Hardware
	if stale.Sensors.State != Stale || stale.Network.State != Stale || stale.Supplies.State != Available || stale.Space.State != Available {
		t.Fatal("incorrect group freshness")
	}
	cancel()
	await(t, e.Done())
}

func TestHostEngineBlockedSpaceIndependent(t *testing.T) {
	release := make(chan struct{})
	entered := make(chan struct{})
	e := NewHostEngine(context.Background(), fixture("meminfo", "MemTotal: 100 kB\nMemAvailable: 40 kB\n"), deniedFS{}, func(at time.Time) Capacity {
		close(entered)
		<-release
		return spaceValues("/", at, 100, 40, 30, 4096, Available)
	})
	defer e.Stop()
	released := false
	defer func() {
		if !released {
			close(release)
		}
	}()
	await(t, entered)
	deadline := time.After(3 * time.Second)
	for {
		s := e.Snapshot(time.Now())
		if s.Memory.Usage.Valid() && s.Hardware.Sensors.State == Permission {
			if s.Hardware.Space.State != Waiting {
				t.Fatal("blocked space fabricated data")
			}
			break
		}
		select {
		case <-e.Changed():
		case <-deadline:
			t.Fatal("blocked space impeded other groups")
		}
	}
	e.Stop()
	close(release)
	released = true
	await(t, e.Done())
}
