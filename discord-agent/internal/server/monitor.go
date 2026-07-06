// Package server monitors players and health, emitting events.
package server

import (
        "context"
        "time"

        "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/events"
)

// StartPlayerMonitor polls RCON every 30s and emits PlayerJoined/PlayerLeft when the list changes.
// Returns when ctx is cancelled.
func (s *Server) StartPlayerMonitor(ctx context.Context) {
        ticker := time.NewTicker(30 * time.Second)
        defer ticker.Stop()

        for {
                select {
                case <-ctx.Done():
                        return
                case <-ticker.C:
                        s.pollPlayers(ctx)
                }
        }
}

// pollPlayers queries the RCON "list", diffs against knownPlayers, and emits join/leave events.
// Events are collected under the lock but published after release to keep the critical section short.
func (s *Server) pollPlayers(ctx context.Context) {
        if s.rcon == nil || !s.cfg.Server.RCON.Enabled {
                return
        }

        players, _, err := s.rcon.PlayerList(ctx)
        if err != nil {
                return
        }

        // Build the current player set; collect events to publish after releasing the lock.
        currentSet := make(map[string]bool, len(players))
        for _, p := range players {
                currentSet[p] = true
        }

        s.mu.Lock()
        var joins []events.Event
        for p := range currentSet {
                if !s.knownPlayers[p] {
                        joins = append(joins, events.Event{
                                EventType:   "PlayerJoined",
                                ServiceName: s.cfg.Server.ServiceName,
                                Stack:       s.cfg.Server.Stack,
                                Metadata:    map[string]string{"player": p},
                        })
                }
        }
        var leaves []events.Event
        for p := range s.knownPlayers {
                if !currentSet[p] {
                        leaves = append(leaves, events.Event{
                                EventType:   "PlayerLeft",
                                ServiceName: s.cfg.Server.ServiceName,
                                Stack:       s.cfg.Server.Stack,
                                Metadata:    map[string]string{"player": p},
                        })
                }
        }
        s.knownPlayers = currentSet
        s.mu.Unlock()

        // Publish events outside the lock — Publish may invoke subscribers.
        for _, e := range joins {
                s.bus.Publish(e)
        }
        for _, e := range leaves {
                s.bus.Publish(e)
        }
}

// StartHealthMonitor polls service health at the configured interval and emits HealthWarning on degradation.
func (s *Server) StartHealthMonitor(ctx context.Context) {
        interval := time.Duration(s.cfg.Features.HealthCheck.IntervalSeconds) * time.Second
        if interval < 60*time.Second {
                interval = 60 * time.Second
        }

        ticker := time.NewTicker(interval)
        defer ticker.Stop()

        for {
                select {
                case <-ctx.Done():
                        return
                case <-ticker.C:
                        s.checkHealth(ctx)
                }
        }
}

// checkHealth emits a HealthWarning if the service is inactive or RCON is unresponsive.
func (s *Server) checkHealth(ctx context.Context) {
        if !s.isServiceActive(ctx, s.cfg.Server.ServiceName) {
                s.bus.Publish(events.Event{
                        EventType:   "HealthWarning",
                        ServiceName: s.cfg.Server.ServiceName,
                        Stack:       s.cfg.Server.Stack,
                        Metadata:    map[string]string{"reason": "service_inactive"},
                })
                return
        }

        // Only probe RCON when it's enabled in config; rcon.NewClient always returns
        // a non-nil client, so the s.rcon != nil guard alone is insufficient.
        if s.rcon != nil && s.cfg.Server.RCON.Enabled {
                _, _, err := s.rcon.PlayerList(ctx)
                if err != nil {
                        s.bus.Publish(events.Event{
                                EventType:   "HealthWarning",
                                ServiceName: s.cfg.Server.ServiceName,
                                Stack:       s.cfg.Server.Stack,
                                Metadata:    map[string]string{"reason": "rcon_unresponsive", "error": err.Error()},
                        })
                }
        }
}
