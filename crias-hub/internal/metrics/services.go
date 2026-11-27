package metrics

import (
	"context"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

const serviceOutputLimit = 4096

type ServiceStatus struct {
	Unit   string
	Load   string
	Active string
	Sub    string
	State  Availability
}

var serviceUnits = [...]string{"minecraft.service", "terraria.service", "sshd.service", "tailscaled.service"}

func allowedService(unit string) bool {
	for _, name := range serviceUnits {
		if unit == name {
			return true
		}
	}
	return false
}

// Limit memory even if an unexpected systemctl implementation emits noise.
// Discard overflow and reject the entire observation.
type serviceOutput struct {
	data     []byte
	overflow bool
}

func (b *serviceOutput) Write(p []byte) (int, error) {
	n := min(len(p), serviceOutputLimit-len(b.data))
	b.data = append(b.data, p[:n]...)
	b.overflow = b.overflow || n != len(p)
	return len(p), nil
}

func querySystemd(parent context.Context, unit string) (string, Availability) {
	if !allowedService(unit) {
		return "", Invalid
	}
	ctx, cancel := context.WithTimeout(parent, time.Second)
	defer cancel()
	// Arch's systemctl path, system manager only. No inherited environment
	// overrides, shell, pager, sudo, user input or mutating verb.
	cmd := exec.CommandContext(ctx, "/usr/bin/systemctl", "--system", "--no-pager", "--no-ask-password", "show", "--property=LoadState", "--property=ActiveState", "--property=SubState", "--", unit)
	cmd.Env = []string{"LANG=C", "LC_ALL=C", "SYSTEMD_COLORS=0"}
	cmd.WaitDelay = 200 * time.Millisecond
	var out serviceOutput
	cmd.Stdout, cmd.Stderr = &out, io.Discard
	err := cmd.Run()
	switch {
	case ctx.Err() != nil:
		return "", Unavailable
	case errors.Is(err, os.ErrPermission):
		return "", Permission
	case err != nil:
		return "", Unavailable
	case out.overflow:
		return "", Invalid
	default:
		return string(out.data), Available
	}
}

func readServices(ctx context.Context, query func(context.Context, string) (string, Availability)) []ServiceStatus {
	out := make([]ServiceStatus, 0, len(serviceUnits))
	for _, unit := range serviceUnits {
		if ctx.Err() != nil {
			break
		}
		raw, state := query(ctx, unit)
		if state == Available {
			out = append(out, parseService(unit, raw))
		} else {
			out = append(out, ServiceStatus{Unit: unit, State: state})
		}
	}
	return out
}

func parseService(unit, raw string) ServiceStatus {
	bad := ServiceStatus{Unit: unit, State: Invalid}
	if !allowedService(unit) || len(raw) > serviceOutputLimit {
		return bad
	}
	fields := make(map[string]string, 3)
	for _, row := range strings.Split(strings.TrimSuffix(raw, "\n"), "\n") {
		key, value, ok := strings.Cut(row, "=")
		if !ok || fields[key] != "" || !serviceToken(value) {
			return bad
		}
		switch key {
		case "LoadState", "ActiveState", "SubState":
			fields[key] = value
		default:
			return bad
		}
	}
	switch fields["LoadState"] {
	case "loaded", "not-found", "masked", "error", "bad-setting", "stub", "merged":
	default:
		return bad
	}
	switch fields["ActiveState"] {
	case "active", "inactive", "failed", "activating", "deactivating", "reloading", "maintenance", "refreshing":
	default:
		return bad
	}
	if fields["SubState"] == "" {
		return bad
	}
	return ServiceStatus{Unit: unit, Load: fields["LoadState"], Active: fields["ActiveState"], Sub: fields["SubState"], State: Available}
}

func serviceToken(s string) bool {
	if len(s) == 0 || len(s) > 40 {
		return false
	}
	for _, r := range s {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
			return false
		}
	}
	return true
}
