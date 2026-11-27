package metrics

import (
	"context"
	"strings"
	"testing"
)

func TestServiceParser(t *testing.T) {
	const good = "LoadState=loaded\nActiveState=active\nSubState=running\n"
	for _, tc := range []struct {
		raw   string
		state Availability
	}{
		{good, Available},
		{"LoadState=not-found\nActiveState=inactive\nSubState=dead\n", Available},
		{"LoadState=loaded\nActiveState=failed\nSubState=failed\n", Available},
		{good + "ActiveState=inactive\n", Invalid},
		{strings.ReplaceAll(good, "running", "running\x1b"), Invalid},
		{"LoadState=loaded\nActiveState=active\n", Invalid},
		{strings.Repeat("x", serviceOutputLimit+1), Invalid},
	} {
		got := parseService("minecraft.service", tc.raw)
		if got.State != tc.state {
			t.Fatalf("%q: %+v", tc.raw, got)
		}
		if tc.state == Invalid && (got.Load != "" || got.Active != "" || got.Sub != "") {
			t.Fatal("invalid output exposed", got)
		}
	}
	if _, state := querySystemd(context.Background(), "--help"); state != Invalid {
		t.Fatal("non-allowlisted unit accepted")
	}
}

func TestServiceCollectionIsolation(t *testing.T) {
	calls := 0
	got := readServices(context.Background(), func(_ context.Context, unit string) (string, Availability) {
		calls++
		if unit == "sshd.service" {
			return "", Permission
		}
		return "LoadState=loaded\nActiveState=inactive\nSubState=dead\n", Available
	})
	if calls != 4 || len(got) != 4 || got[2].State != Permission || got[3].Active != "inactive" {
		t.Fatal(calls, got)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if len(readServices(ctx, func(context.Context, string) (string, Availability) {
		t.Fatal("query after cancellation")
		return "", Invalid
	})) != 0 {
		t.Fatal("cancelled collector emitted results")
	}
	var b serviceOutput
	n, err := b.Write(make([]byte, serviceOutputLimit+5))
	if err != nil || n != serviceOutputLimit+5 || !b.overflow || len(b.data) != serviceOutputLimit {
		t.Fatal("output limit failed")
	}
}
