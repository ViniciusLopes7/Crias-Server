// Package server helpers para monitorar players e emitir eventos.
package server

import (
	"context"
	"time"

	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/events"
)

// StartPlayerMonitor inicia uma goroutine que consulta RCON a cada 30s
// e emite eventos PlayerJoined/PlayerLeft quando a lista muda.
// Retorna quando ctx é cancelado.
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

// pollPlayers consulta RCON "list", compara com knownPlayers e emite eventos.
//
// 2B-009: coleta eventos DEPOIS de soltar o lock. Antes, Publish era
// chamado com s.mu segurada, estendendo a critical section e podendo
// deadlockar se Publish algum dia bloqueasse (atualmente é non-blocking,
// mas a regra de nunca segurar lock durante I/O externa é defense-in-depth).
func (s *Server) pollPlayers(ctx context.Context) {
	if s.rcon == nil {
		return
	}

	players, _, err := s.rcon.PlayerList()
	if err != nil {
		return
	}

	// Monta set de players atuais e coleta eventos DEPOIS de soltar o lock.
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

	// Publica eventos FORA do lock — Publish pode chamar subscribers
	// (que rodam em goroutines próprias), então nem sequer tocamos s.mu aqui.
	for _, e := range joins {
		s.bus.Publish(e)
	}
	for _, e := range leaves {
		s.bus.Publish(e)
	}

	// GO-027: lastPlayerPoll field removido do Server struct (era dead code
	// — escrito mas nunca lido). Se precisar tracker do último poll no futuro,
	// re-adicione o campo em server.go antes de usar aqui.
}

// StartHealthMonitor inicia goroutine que verifica saúde a cada N segundos
// e emite HealthWarning se servidor estiver degradado.
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

// checkHealth verifica se serviço está ativo e RCON responde.
// Só notifica em caso de problema (passivo).
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

	if s.rcon != nil {
		_, _, err := s.rcon.PlayerList()
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
