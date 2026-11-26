package metrics

import (
	"context"
	"os"
	"testing"
	"time"
)

// Run only in the disposable Arch VM after its existing fixture has
// established the expected service state. This test never changes a unit.
func TestRealSystemdReadOnly(t *testing.T) {
	want := os.Getenv("CRIAS_HUB_REAL_SYSTEMD")
	if want == "" {
		t.Skip("requires disposable Arch/systemd fixture")
	}
	if os.Geteuid() == 0 || (want != "active" && want != "inactive") {
		t.Fatal("invalid integration fixture")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	got := readServices(ctx, querySystemd)
	if len(got) != len(serviceUnits) {
		t.Fatal("incomplete collection", got)
	}
	for _, v := range got {
		t.Logf("%s: %s/%s/%s (%s)", v.Unit, v.Load, v.Active, v.Sub, v.State)
	}
	for _, tc := range []struct {
		unit   string
		active string
		sub    string
	}{
		{"minecraft.service", want, map[string]string{"active": "running", "inactive": "dead"}[want]},
		{"sshd.service", "active", "running"},
	} {
		found := false
		for _, v := range got {
			if v.Unit == tc.unit {
				found = true
				if v.State != Available || v.Load != "loaded" || v.Active != tc.active || v.Sub != tc.sub {
					t.Fatalf("unexpected real unit state: %+v; want %s/%s", v, tc.active, tc.sub)
				}
			}
		}
		if !found {
			t.Fatal("missing unit", tc.unit)
		}
	}
}
