// cmd/crias-agent/main.go é o entry point do agente Crias.
//
// O agente é um binário Go estático que:
//   1. Lê /etc/crias/agent.yaml
//   2. Inicia servidor gRPC em localhost:8473
//   3. Autentica via metadata x-api-token
//   4. Delega comandos para sudo systemctl e mc-manager.sh
//   5. Monitora players via RCON e emite eventos
package main

import (
        "context"
        "flag"
        "fmt"
        "log"
        "net"
        "os"
        "os/signal"
        "syscall"
        "time"

        "google.golang.org/grpc"

        "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/config"
        "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/events"
        "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/rcon"
        "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/server"

        criasv1 "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/proto"
)

var (
        version = "dev"
        configPath = flag.String("config", "", "caminho para agent.yaml (default: /etc/crias/agent.yaml)")
        showVersion = flag.Bool("version", false, "exibe versão e sai")
)

func main() {
        flag.Parse()

        if *showVersion {
                fmt.Printf("crias-agent %s\n", version)
                os.Exit(0)
        }

        path := *configPath
        if path == "" {
                path = config.DefaultConfigPath()
        }

        cfg, err := config.Load(path)
        if err != nil {
                log.Fatalf("carregar config %s: %v", path, err)
        }

        log.Printf("crias-agent %s iniciando — stack=%s service=%s bind=%s:%d",
                version, cfg.Server.Stack, cfg.Server.ServiceName,
                cfg.Agent.BindAddress, cfg.Agent.Port)

        // Inicializa componentes.
        rconClient := rcon.NewClient(
                cfg.Server.RCON.Host,
                cfg.Server.RCON.Port,
                cfg.Server.RCON.Password,
                cfg.Server.RCON.Enabled,
        )
        defer rconClient.Close()

        bus := events.NewBus()

        srv := server.New(cfg, rconClient, bus)

        // Inicia monitores em background.
        ctx, cancel := context.WithCancel(context.Background())
        defer cancel()

        go srv.StartPlayerMonitor(ctx)
        go srv.StartHealthMonitor(ctx)
        go srv.StartAutoShutdownMonitor(ctx)

        // Configura servidor gRPC.
        addr := fmt.Sprintf("%s:%d", cfg.Agent.BindAddress, cfg.Agent.Port)
        lis, err := net.Listen("tcp", addr)
        if err != nil {
                log.Fatalf("escutar %s: %v", addr, err)
        }

        grpcSrv := grpc.NewServer(
                grpc.UnaryInterceptor(server.AuthInterceptor(cfg.Agent.AuthToken)),
                grpc.StreamInterceptor(server.StreamAuthInterceptor(cfg.Agent.AuthToken)),
                grpc.MaxRecvMsgSize(64 * 1024),  // 64 KB por mensagem (comando RCON não precisa ser grande)
                grpc.MaxSendMsgSize(1 * 1024 * 1024), // 1 MB para stream de console
        )

        criasv1.RegisterServerControlServer(grpcSrv, srv)
        criasv1.RegisterEventBusServer(grpcSrv, srv)

        // Graceful shutdown.
        go func() {
                sigCh := make(chan os.Signal, 1)
                signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
                defer signal.Stop(sigCh)
                sig := <-sigCh
                log.Printf("sinal %v recebido, parando graciosamente...", sig)
                cancel()
                grpcSrv.GracefulStop()
        }()

        log.Printf("servindo gRPC em %s", addr)
        // NÃO usar log.Fatalf aqui — ele chama os.Exit(1) e pula defer cancel()
        // e defer rconClient.Close(). Retornar normalmente garante cleanup.
        if err := grpcSrv.Serve(lis); err != nil {
                log.Printf("gRPC Serve falhou: %v", err)
                return
        }

        // Pequeno delay para garantir flush de logs.
        time.Sleep(100 * time.Millisecond)
        log.Printf("crias-agent finalizado")
}
