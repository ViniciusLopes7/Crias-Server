// Package server implementa os serviços gRPC ServerControl e EventBus.
package server

import (
        "bytes"
        "context"
        "crypto/subtle"
        "fmt"
        "io"
        "os/exec"
        "strings"
        "sync"
        "time"

        "google.golang.org/grpc"
        "google.golang.org/grpc/codes"
        "google.golang.org/grpc/metadata"
        "google.golang.org/grpc/status"

        "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/config"
        "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/events"
        "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/rcon"

        criasv1 "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/proto"
)

// Version é a versão do agente (override em build com -ldflags).
var Version = "dev"

// Server implementa criasv1.ServerControlServer e criasv1.EventBusServer.
type Server struct {
        criasv1.UnimplementedServerControlServer
        criasv1.UnimplementedEventBusServer

        cfg     *config.Config
        rcon    *rcon.Client
        bus     *events.Bus

        // Estado interno.
        mu             sync.Mutex
        knownPlayers   map[string]bool   // para detectar join/leave
        lastPlayerPoll time.Time
}

// New cria uma nova instância do servidor gRPC.
func New(cfg *config.Config, rconClient *rcon.Client, bus *events.Bus) *Server {
        return &Server{
                cfg:          cfg,
                rcon:         rconClient,
                bus:          bus,
                knownPlayers: make(map[string]bool),
        }
}

// AuthInterceptor valida o token x-api-token em cada RPC.
func AuthInterceptor(authToken string) grpc.UnaryServerInterceptor {
        return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
                if err := validateToken(ctx, authToken); err != nil {
                        return nil, err
                }
                return handler(ctx, req)
        }
}

// StreamAuthInterceptor valida o token em streams (SubscribeEvents, StreamConsole).
func StreamAuthInterceptor(authToken string) grpc.StreamServerInterceptor {
        return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
                if err := validateToken(ss.Context(), authToken); err != nil {
                        return err
                }
                return handler(srv, ss)
        }
}

func validateToken(ctx context.Context, expected string) error {
        md, ok := metadata.FromIncomingContext(ctx)
        if !ok {
                return status.Error(codes.Unauthenticated, "metadata ausente")
        }
        tokens := md.Get("x-api-token")
        if len(tokens) == 0 {
                return status.Error(codes.Unauthenticated, "x-api-token metadata ausente")
        }
        // Constant-time comparison para prevenir timing attacks.
        if subtle.ConstantTimeCompare([]byte(tokens[0]), []byte(expected)) != 1 {
                return status.Error(codes.Unauthenticated, "token inválido")
        }
        return nil
}

// --- ServerControl RPCs ---

// StartServer delega para `sudo systemctl start <service>`.
func (s *Server) StartServer(ctx context.Context, req *criasv1.StartRequest) (*criasv1.StartResponse, error) {
        out, err := s.runSystemctl(ctx, "start", s.cfg.Server.ServiceName)
        if err != nil {
                s.bus.Publish(events.Event{
                        EventType:     "HealthWarning",
                        ServiceName:   s.cfg.Server.ServiceName,
                        Stack:         s.cfg.Server.Stack,
                        Metadata:      map[string]string{"reason": "start_failed", "error": err.Error(), "output": out},
                })
                return &criasv1.StartResponse{
                        Ok:           false,
                        Message:      fmt.Sprintf("falha: %v (output: %s)", err, out),
                        ServiceName:  s.cfg.Server.ServiceName,
                }, nil
        }

        s.bus.Publish(events.Event{
                EventType:     "ServerStarted",
                ServiceName:   s.cfg.Server.ServiceName,
                Stack:         s.cfg.Server.Stack,
                Metadata:      map[string]string{"force": fmt.Sprintf("%v", req.GetForce())},
        })

        return &criasv1.StartResponse{
                Ok:          true,
                Message:     "servidor iniciado",
                ServiceName: s.cfg.Server.ServiceName,
        }, nil
}

// StopServer delega para `sudo systemctl stop <service>`.
func (s *Server) StopServer(ctx context.Context, req *criasv1.StopRequest) (*criasv1.StopResponse, error) {
        out, err := s.runSystemctl(ctx, "stop", s.cfg.Server.ServiceName)
        if err != nil {
                return &criasv1.StopResponse{
                        Ok:          false,
                        Message:     fmt.Sprintf("falha: %v (output: %s)", err, out),
                        ServiceName: s.cfg.Server.ServiceName,
                }, nil
        }

        s.bus.Publish(events.Event{
                EventType:     "ServerStopped",
                ServiceName:   s.cfg.Server.ServiceName,
                Stack:         s.cfg.Server.Stack,
                Metadata:      map[string]string{"timeout_seconds": fmt.Sprintf("%d", req.GetTimeoutSeconds())},
        })

        return &criasv1.StopResponse{
                Ok:          true,
                Message:     "servidor parado",
                ServiceName: s.cfg.Server.ServiceName,
        }, nil
}

// RestartServer delega para `sudo systemctl restart <service>`.
func (s *Server) RestartServer(ctx context.Context, req *criasv1.RestartRequest) (*criasv1.RestartResponse, error) {
        out, err := s.runSystemctl(ctx, "restart", s.cfg.Server.ServiceName)
        if err != nil {
                return &criasv1.RestartResponse{
                        Ok:          false,
                        Message:     fmt.Sprintf("falha: %v (output: %s)", err, out),
                        ServiceName: s.cfg.Server.ServiceName,
                }, nil
        }

        s.bus.Publish(events.Event{
                EventType:     "ServerStarted",
                ServiceName:   s.cfg.Server.ServiceName,
                Stack:         s.cfg.Server.Stack,
                Metadata:      map[string]string{"reason": "restart"},
        })

        return &criasv1.RestartResponse{
                Ok:          true,
                Message:     "servidor reiniciado",
                ServiceName: s.cfg.Server.ServiceName,
        }, nil
}

// GetStatus retorna status consolidado: systemd + RCON players.
func (s *Server) GetStatus(ctx context.Context, req *criasv1.GetStatusRequest) (*criasv1.StatusResponse, error) {
        active := s.isServiceActive(ctx, s.cfg.Server.ServiceName)

        resp := &criasv1.StatusResponse{
                ServiceName: s.cfg.Server.ServiceName,
                Stack:       s.cfg.Server.Stack,
                Version:     Version,
        }

        if active {
                resp.ServiceActive = true
                resp.UptimeSeconds = s.getServiceUptime(ctx, s.cfg.Server.ServiceName)

                // Tenta buscar players via RCON (best-effort).
                if s.rcon != nil {
                        players, maxPlayers, err := s.rcon.PlayerList()
                        if err == nil {
                                resp.Players = players
                                resp.PlayerCount = int32(len(players))
                                resp.MaxPlayers = int32(maxPlayers)
                        }
                }
        }

        return resp, nil
}

// GetHealth verifica se porta está em escuta + RCON responde.
func (s *Server) GetHealth(ctx context.Context, req *criasv1.GetHealthRequest) (*criasv1.HealthResponse, error) {
        resp := &criasv1.HealthResponse{
                ServiceName: s.cfg.Server.ServiceName,
        }

        // Se RCON habilitado, testa resposta.
        if s.rcon != nil {
                _, _, err := s.rcon.PlayerList()
                if err == nil {
                        resp.RconResponsive = true
                }
        }

        resp.Healthy = resp.RconResponsive
        if resp.Healthy {
                resp.Message = "healthy"
        } else {
                resp.Message = "rcon indisponível ou servidor offline"
        }

        return resp, nil
}

// SendRconCommand executa comando RCON whitelistado.
func (s *Server) SendRconCommand(ctx context.Context, req *criasv1.SendRconCommandRequest) (*criasv1.SendRconCommandResponse, error) {
        command := strings.TrimSpace(req.GetCommand())
        if command == "" {
                return &criasv1.SendRconCommandResponse{
                        Ok:    false,
                        Error: "comando vazio",
                }, nil
        }

        if !rcon.IsCommandAllowed(command) {
                return &criasv1.SendRconCommandResponse{
                        Ok:    false,
                        Error: fmt.Sprintf("comando %q não está na whitelist", strings.Fields(command)[0]),
                }, nil
        }

        if s.rcon == nil {
                return &criasv1.SendRconCommandResponse{
                        Ok:    false,
                        Error: "rcon desabilitado na configuração",
                }, nil
        }

        out, err := s.rcon.Execute(command)
        if err != nil {
                return &criasv1.SendRconCommandResponse{
                        Ok:    false,
                        Error: err.Error(),
                }, nil
        }

        return &criasv1.SendRconCommandResponse{
                Ok:     true,
                Output: out,
        }, nil
}

// StreamConsole faz tail de `journalctl -u <service> -f` e envia linhas.
func (s *Server) StreamConsole(req *criasv1.StreamConsoleRequest, stream criasv1.ServerControl_StreamConsoleServer) error {
        ctx := stream.Context()
        tailLines := int(req.GetTailLines())
        if tailLines <= 0 {
                tailLines = 50
        }

        // journalctl -u minecraft -f -n 50 --output=cat
        args := []string{
                "-u", s.cfg.Server.ServiceName,
                "-f",
                "-n", fmt.Sprintf("%d", tailLines),
                "--output=cat",
                "--no-pager",
        }
        cmd := exec.CommandContext(ctx, "journalctl", args...)
        stdout, err := cmd.StdoutPipe()
        if err != nil {
                return status.Errorf(codes.Internal, "criar pipe: %v", err)
        }
        if err := cmd.Start(); err != nil {
                return status.Errorf(codes.Internal, "iniciar journalctl: %v", err)
        }
        defer cmd.Wait()

        buf := make([]byte, 0, 8192)
        tmp := make([]byte, 4096)
        for {
                select {
                case <-ctx.Done():
                        cmd.Process.Kill()
                        return ctx.Err()
                default:
                }
                n, err := stdout.Read(tmp)
                if n > 0 {
                        buf = append(buf, tmp[:n]...)
                        // Quebra em linhas usando bytes.IndexByte da stdlib.
                        for {
                                idx := bytes.IndexByte(buf, '\n')
                                if idx < 0 {
                                        break
                                }
                                line := string(buf[:idx])
                                buf = buf[idx+1:]
                                if err := stream.Send(&criasv1.ConsoleLine{
                                        Line:           strings.TrimRight(line, "\r"),
                                        TimestampUnix:  time.Now().Unix(),
                                }); err != nil {
                                        cmd.Process.Kill()
                                        return err
                                }
                        }
                }
                if err == io.EOF {
                        break
                }
                if err != nil {
                        cmd.Process.Kill()
                        return status.Errorf(codes.Internal, "ler journalctl: %v", err)
                }
        }
        return nil
}

// --- EventBus RPCs ---

// SubscribeEvents abre stream de eventos para o cliente.
func (s *Server) SubscribeEvents(req *criasv1.SubscribeEventsRequest, stream criasv1.EventBus_SubscribeEventsServer) error {
        ctx := stream.Context()
        ch, cancel := s.bus.Subscribe(req.GetEventTypes())
        defer cancel()

        for {
                select {
                case <-ctx.Done():
                        return ctx.Err()
                case ev, ok := <-ch:
                        if !ok {
                                return nil
                        }
                        if err := stream.Send(eventToProto(ev)); err != nil {
                                return err
                        }
                }
        }
}

// --- Helpers ---

// runSystemctl executa sudo systemctl <op> <service> e retorna output.
func (s *Server) runSystemctl(ctx context.Context, op string, service string) (string, error) {
        cmd := exec.CommandContext(ctx, "sudo", "systemctl", op, service)
        out, err := cmd.CombinedOutput()
        return string(out), err
}

// isServiceActive retorna true se `systemctl is-active --quiet <service>` exit 0.
func (s *Server) isServiceActive(ctx context.Context, service string) bool {
        cmd := exec.CommandContext(ctx, "systemctl", "is-active", "--quiet", service)
        return cmd.Run() == nil
}

// getServiceUptime retorna uptime em segundos baseado em ExecMainStartTimestamp.
func (s *Server) getServiceUptime(ctx context.Context, service string) int64 {
        cmd := exec.CommandContext(ctx, "systemctl", "show", "-p", "ExecMainStartTimestamp", "--value", service)
        out, err := cmd.Output()
        if err != nil {
                return 0
        }
        ts := strings.TrimSpace(string(out))
        if ts == "" || ts == "0" {
                return 0
        }
        t, err := time.Parse("Mon 2006-01-02 15:04:05 MST", ts)
        if err != nil {
                return 0
        }
        return int64(time.Since(t).Seconds())
}

// eventToProto converte events.Event → criasv1.ServerEvent.
func eventToProto(ev events.Event) *criasv1.ServerEvent {
        return &criasv1.ServerEvent{
                EventId:       ev.EventID,
                EventType:     ev.EventType,
                TimestampUnix: ev.TimestampUnix,
                ServiceName:   ev.ServiceName,
                Stack:         ev.Stack,
                Metadata:      ev.Metadata,
        }
}
