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
