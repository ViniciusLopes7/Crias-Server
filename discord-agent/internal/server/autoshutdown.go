// Package server auto-shutdown monitor.
//
// When AutoShutdown.Enabled is true, stops the server after it has been empty
// for EmptyMinutes. Does not restart — only stops.
package server

import (
	"context"
	"fmt"
	"log"
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

	state := &autoShutdownState{}

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Fix B6: don't count down when the service is already stopped (manually or
			// by a prior auto-shutdown). Resetting emptySince avoids a stale countdown
			// resuming the moment the service is started again.
			if !s.isServiceActive(ctx, s.cfg.Server.ServiceName) {
				state.emptySince = time.Time{}
				continue
			}

			playerCount, err := s.getCurrentPlayerCount(ctx)
			switch advanceAutoShutdown(state, emptyMinutes, time.Now(), playerCount, err) {
			case autoShutdownUnknown:
				// EXP-45: the player count is UNKNOWN (RCON failure or unparseable
				// "list" response) — it must NOT be treated as 0 players. Skip this
				// cycle entirely (the countdown state is left untouched) and warn.
				log.Printf("auto-shutdown: contagem de players desconhecida, pulando ciclo: %v", err)
				s.bus.Publish(events.Event{
					EventType:   "HealthWarning",
					ServiceName: s.cfg.Server.ServiceName,
					Stack:       s.cfg.Server.Stack,
					Metadata: map[string]string{
						"reason": "auto_shutdown_player_count_unknown",
						"error":  err.Error(),
					},
				})
			case autoShutdownReset:
				// Players online — the countdown was reset inside advanceAutoShutdown.
			case autoShutdownBegin:
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
			case autoShutdownIdle:
				// Empty, countdown still running — nothing to do.
			case autoShutdownStop:
				// Empty window elapsed — trigger shutdown.
				s.bus.Publish(events.Event{
					EventType:   "HealthWarning",
					ServiceName: s.cfg.Server.ServiceName,
					Stack:       s.cfg.Server.Stack,
					Metadata: map[string]string{
						"reason":        "auto_shutdown_triggered",
						"empty_seconds": strconv.Itoa(int(time.Since(state.triggeredAt).Seconds())),
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
				// emptySince was already reset inside advanceAutoShutdown —
				// even on stop failure, to avoid a retry loop.
			}
		}
	}
}

// autoShutdownState carries the empty-countdown across evaluation cycles.
type autoShutdownState struct {
	// emptySince is when the server was first CONFIRMED empty; zero = not counting.
	emptySince time.Time
	// triggeredAt is set when the stop decision fires (before the state is
	// reset), so the event can report the real elapsed window.
	triggeredAt time.Time
}

// autoShutdownDecision is the outcome of one evaluation cycle.
type autoShutdownDecision int

const (
	// autoShutdownUnknown: the player count could not be determined — skip the
	// cycle without touching the countdown (EXP-45).
	autoShutdownUnknown autoShutdownDecision = iota
	// autoShutdownReset: players online — countdown reset.
	autoShutdownReset
	// autoShutdownBegin: server just became empty — countdown started.
	autoShutdownBegin
	// autoShutdownIdle: empty, countdown still running.
	autoShutdownIdle
	// autoShutdownStop: empty window elapsed — stop the server.
	autoShutdownStop
)

// advanceAutoShutdown advances the empty-countdown state machine by one
// observation. It is a pure function (apart from mutating st) so the gating
// logic is unit-testable without RCON/systemctl (EXP-45).
func advanceAutoShutdown(st *autoShutdownState, emptyMinutes int, now time.Time, count int, countErr error) autoShutdownDecision {
	if countErr != nil {
		// Count UNKNOWN (RCON/parse error): never treat as 0 players. Skip the
		// cycle — leave emptySince untouched (a later confirmed-empty cycle
		// still requires count == 0 before stopping).
		return autoShutdownUnknown
	}
	if count > 0 {
		st.emptySince = time.Time{} // reset
		return autoShutdownReset
	}

	// Server is confirmed empty.
	if st.emptySince.IsZero() {
		st.emptySince = now
		return autoShutdownBegin
	}
	if now.Sub(st.emptySince) >= time.Duration(emptyMinutes)*time.Minute {
		st.triggeredAt = st.emptySince
		st.emptySince = time.Time{}
		return autoShutdownStop
	}
	return autoShutdownIdle
}

// getCurrentPlayerCount returns the RCON player count. An error indicates the
// count could not be determined (RCON failure, RCON disabled or unparseable
// "list" response); callers must NOT treat (0, err) as "empty" — see
// StartAutoShutdownMonitor and advanceAutoShutdown.
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
