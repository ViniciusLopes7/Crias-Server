package metrics

import (
	"testing"
	"time"
)

func TestTransfers(t *testing.T) {
	at := time.Unix(100, 0)
	var c TransferCollector
	header := "Inter-| Receive | Transmit\n face | bytes | bytes\n"
	first := header + "eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\n"
	second := header + "eth0: 5000 0 0 0 0 0 0 0 8000 0 0 0 0 0 0 0\n"
	got := c.Read(fixture("net/dev", first), at)
	if got.State != Available || len(got.Values) != 1 || got.Values[0].ReadRate.State != Waiting {
		t.Fatal(got)
	}
	got = c.Read(fixture("net/dev", second), at.Add(2*time.Second))
	if got.Values[0].ReadRate.Value != 2000 || got.Values[0].WriteRate.Value != 3000 || !got.Values[0].ReadRate.Valid() {
		t.Fatal(got)
	}
	got = c.Read(fixture("net/dev", first), at.Add(4*time.Second))
	if got.Values[0].ReadRate.State != Invalid {
		t.Fatal("reset accepted", got)
	}
	if c.Read(deniedFS{}, at).State != Permission {
		t.Fatal("permission lost")
	}
	got = c.Read(fixture("net/dev", second), at.Add(5*time.Second))
	if got.Values[0].ReadRate.State != Waiting {
		t.Fatal("failure bridged", got)
	}
	got = c.Read(fixture("net/dev", second), at.Add(30*time.Second))
	if got.Values[0].ReadRate.State != Stale {
		t.Fatal("gap not detected", got)
	}
}

func TestDiskSectorUnits(t *testing.T) {
	at := time.Unix(100, 0)
	c := TransferCollector{Disk: true}
	c.Read(fixture("diskstats", "8 0 sda 0 0 10 0 0 0 20 0 0 0 0\n"), at)
	got := c.Read(fixture("diskstats", "8 0 sda 0 0 14 0 0 0 28 0 0 0 0\n"), at.Add(2*time.Second))
	if got.State != Available || len(got.Values) != 1 || got.Values[0].ReadRate.Value != 1024 || got.Values[0].WriteRate.Value != 2048 {
		t.Fatal(got)
	}
	if c.Read(fixture("diskstats", "8 0 sda 0 0 18446744073709551615 0 0 0 20 0 0 0 0\n"), at).State != Invalid {
		t.Fatal("overflow accepted")
	}
}

func TestSpaceReservedBlocks(t *testing.T) {
	got := spaceValues("/", time.Time{}, 100, 40, 30, 4096, Available)
	if got.Total.Value != 409600 || got.Available.Value != 122880 || got.Used.Value != 245760 || !got.Usage.Valid() {
		t.Fatal(got)
	}
	if got := spaceValues("/", time.Time{}, 100, 40, 41, 4096, Available); got.Total.State != Invalid {
		t.Fatal("invalid free space", got)
	}
}

func TestThermalZones(t *testing.T) {
	sys := fixture("class/thermal/thermal_zone0/temp", "42000")
	got := ReadThermalZones(sys, time.Unix(100, 0))
	if got.State != Available || len(got.Values) != 1 || got.Values[0].Value.Value != 42 {
		t.Fatal(got)
	}
}
