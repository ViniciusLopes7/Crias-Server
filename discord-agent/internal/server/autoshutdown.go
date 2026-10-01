// Package server auto-shutdown monitor.
//
// When AutoShutdown.Enabled is true, stops the server after it has been empty
// for EmptyMinutes. Does not restart — only stops.
package server

import (
	"context"
	"fmt"
	"strconv"
	"time"

	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/events"
)

// StartAutoShutdownMonitor stops the server when it has been empty for EmptyMinutes.
// Returns when ctx is cancelled.
func (s *Server) StartAutoShutdownMonitor(ctx context.Context) {
	if !s.cfg.Features.AutoShutdown.Enabled {
		return
	}

	emptyMinutes := s.cfg.Features.AutoShutdown.EmptyMinutes
	if emptyMinutes <= 0 {
		emptyMinutes = 30
	}

	interval := time.Duration(emptyMinutes) * time.Minute / 4 // check 4x per empty window
	if interval < 30*time.Second {
		interval = 30 * time.Second
	}
	if interval > 5*time.Minute {
		interval = 5 * time.Minute
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	var emptySince time.Time

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Fix B6: don't count down when the service is already stopped (manually or
			// by a prior auto-shutdown). Resetting emptySince avoids a stale countdown
			// resuming the moment the service is started again.
			if !s.isServiceActive(ctx, s.cfg.Server.ServiceName) {
				emptySince = time.Time{}
				continue
			}

			playerCount, err := s.getCurrentPlayerCount(ctx)
			if err != nil {
				// RCON error: can't confirm emptiness, so don't advance the countdown.
				// Emit a HealthWarning so operators see the RCON failure.
				s.bus.Publish(events.Event{
					EventType:   "HealthWarning",
					ServiceName: s.cfg.Server.ServiceName,
					Stack:       s.cfg.Server.Stack,
					Metadata: map[string]string{
						"reason": "auto_shutdown_rcon_error",
						"error":  err.Error(),
					},
				})
				continue
			}
			if playerCount > 0 {
				emptySince = time.Time{} // reset
				continue
			}

			// Server is empty.
			if emptySince.IsZero() {
				emptySince = time.Now()
				s.bus.Publish(events.Event{
					EventType:   "HealthWarning",
					ServiceName: s.cfg.Server.ServiceName,
					Stack:       s.cfg.Server.Stack,
					Metadata: map[string]string{
						"reason":          "auto_shutdown_countdown",
						"empty_minutes":   strconv.Itoa(emptyMinutes),
						"shutdown_in_min": strconv.Itoa(emptyMinutes),
					},
				})
				continue
			}

			elapsed := time.Since(emptySince)
			if elapsed >= time.Duration(emptyMinutes)*time.Minute {
				// Trigger shutdown.
				s.bus.Publish(events.Event{
					EventType:   "HealthWarning",
					ServiceName: s.cfg.Server.ServiceName,
					Stack:       s.cfg.Server.Stack,
					Metadata: map[string]string{
						"reason":        "auto_shutdown_triggered",
						"empty_seconds": strconv.Itoa(int(elapsed.Seconds())),
					},
				})

				// Run systemctl stop; only publish ServerStopped on success.
				// Wrap with a deadline so a hung sudo/systemctl can't block
				// the auto-shutdown goroutine indefinitely (G5).
				stopCtx, stopCancel := withDeadline(ctx, defaultRPCDeadline)
				stopOut, stopErr := s.runSystemctl(stopCtx, "stop", s.cfg.Server.ServiceName)
				stopCancel()
				if stopErr != nil {
					s.bus.Publish(events.Event{
						EventType:   "HealthWarning",
						ServiceName: s.cfg.Server.ServiceName,
						Stack:       s.cfg.Server.Stack,
						Metadata: map[string]string{
							"reason": "auto_shutdown_failed",
							"error":  stopErr.Error(),
							"output": stopOut,
						},
					})
				} else {
					s.bus.Publish(events.Event{
						EventType:   "ServerStopped",
						ServiceName: s.cfg.Server.ServiceName,
						Stack:       s.cfg.Server.Stack,
						Metadata: map[string]string{
							"reason": "auto_shutdown_empty",
						},
					})
				}

				emptySince = time.Time{} // reset after attempt (even on failure, to avoid retry loop)
			}
		}
	}
}

// getCurrentPlayerCount returns the RCON player count. An error indicates the
// count could not be determined (RCON failure or RCON disabled); callers must
// NOT treat (0, err) as "empty" — see StartAutoShutdownMonitor.
func (s *Server) getCurrentPlayerCount(ctx context.Context) (int, error) {
	if s.rcon == nil {
		return 0, fmt.Errorf("rcon client não inicializado")
	}
	players, _, err := s.rcon.PlayerList(ctx)
	if err != nil {
		return 0, err
	}
	return len(players), nil
}
