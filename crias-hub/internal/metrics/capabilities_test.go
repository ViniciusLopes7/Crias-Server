package metrics

import (
	"math"
	"testing"
)

func TestCapabilityEvidence(t *testing.T) {
	h := HardwareSnapshot{}
	h.Sensors.State = Available
	h.Sensors.Data.Values = []Sensor{
		{Value: Sample{Unit: RPM, State: Available, Value: 0}},
		{Value: Sample{Unit: RPM, State: Permission}},
		{Value: Sample{Unit: Celsius, State: Available, Value: math.NaN()}},
	}
	h.Frequencies.State = Available
	h.Frequencies.Data.Policies = []FrequencyPolicy{
		{Observed: Sample{Unit: MHz, State: Unavailable}, Requested: Sample{Unit: MHz, State: Estimated, Value: 2300}},
	}
	h.Supplies.State = Available
	h.Supplies.Data.Batteries = []Battery{
		{Present: Sample{Unit: Boolean, State: Available, Value: 0}, Capacity: Sample{Unit: Percent, State: Available, Value: 80}},
		{Capacity: Sample{Unit: Percent, State: Available, Value: 70}, EndLimit: Sample{Unit: Percent, State: Available, Value: 80}},
	}
	got := Capabilities(h)
	if len(got) != 12 || got[0].Missing != 1 || got[1].Estimated != 1 || got[2].Invalid != 1 || got[3].Observed != 1 || got[3].Denied != 1 || got[6].Observed != 1 || got[9].Observed != 1 {
		t.Fatal(got)
	}
	h.Sensors.State = Stale
	got = Capabilities(h)
	if got[3].Group != Stale || got[3].Observed != 0 || got[3].Denied != 0 {
		t.Fatal("stale evidence exposed", got[3])
	}
}

func TestCapabilityNoEvidence(t *testing.T) {
	h := HardwareSnapshot{}
	h.Sensors.State = Available
	h.Supplies.State = Permission
	got := Capabilities(h)
	if got[3].Observed != 0 || got[3].Missing != 0 || got[3].Group != Available {
		t.Fatal(got[3])
	}
	if got[6].Group != Permission || got[6].Observed != 0 {
		t.Fatal(got[6])
	}
}

func TestPowerCapabilityEvidence(t *testing.T) {
	sample := func(state Availability, unit Unit, value float64) Sample {
		return Sample{State: state, Unit: unit, Value: value}
	}
	missing := sample(Unavailable, Watts, 0)
	denied := sample(Permission, Watts, 0)
	invalid := sample(Invalid, Watts, 0)
	stale := sample(Stale, Watts, 0)
	waiting := sample(Waiting, Watts, 0)
	measured := sample(Available, Watts, 12)
	estimated := sample(Estimated, Watts, 11)
	badUnit := sample(Available, MHz, 12)
	badValue := sample(Available, Watts, math.Inf(1))
	for _, tc := range []struct {
		name             string
		instant, average Sample
		want             Capability
	}{
		{"denied and missing", denied, missing, Capability{Denied: 1}},
		{"missing and denied", missing, denied, Capability{Denied: 1}},
		{"invalid and waiting", invalid, waiting, Capability{Invalid: 1}},
		{"wrong unit and missing", badUnit, missing, Capability{Invalid: 1}},
		{"nonfinite and denied", badValue, denied, Capability{Invalid: 1}},
		{"stale and waiting", stale, waiting, Capability{Stale: 1}},
		{"missing and waiting", missing, waiting, Capability{Waiting: 1}},
		{"both missing", missing, missing, Capability{Missing: 1}},
		{"denied and measured", denied, measured, Capability{Observed: 1}},
		{"measured and invalid", measured, invalid, Capability{Observed: 1}},
		{"estimated and measured", estimated, measured, Capability{Observed: 1}},
		{"estimated and denied", estimated, denied, Capability{Estimated: 1}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := HardwareSnapshot{}
			h.Domains.State = Available
			h.Domains.Data.Values = []PowerDomain{{Instant: tc.instant, Average: tc.average}}
			got := Capabilities(h)[5]
			want := tc.want
			want.Name, want.Group = "Potência por domínio", Available
			if got != want {
				t.Fatalf("got %+v, want %+v", got, want)
			}
			h.Domains.State = Stale
			if got := Capabilities(h)[5]; got != (Capability{Name: want.Name, Group: Stale}) {
				t.Fatalf("stale group exposed evidence: %+v", got)
			}
		})
	}
}
