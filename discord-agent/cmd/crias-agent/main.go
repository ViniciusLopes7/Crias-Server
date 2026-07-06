// cmd/crias-agent/main.go é o entry point do agente Crias.
//
// O agente é um binário Go estático que:
//
//  1. Lê /etc/crias/agent.yaml
//  2. Inicia servidor gRPC em localhost:8473 (ou TLS se configurado)
//  3. Autentica via metadata x-api-token
//  4. Delega comandos para sudo systemctl e mc-manager.sh
//  5. Monitora players via RCON e emite eventos
package main

import (
	"context"
	"crypto/tls"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"runtime/debug"
	"syscall"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/config"
	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/events"
	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/rcon"
	"github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/server"

	criasv1 "github.com/ViniciusLopes7/Crias-Server/discord-agent/internal/proto"
)

var (
	version     = "dev"
	configPath  = flag.String("config", "", "caminho para agent.yaml (default: /etc/crias/agent.yaml)")
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

	log.Printf("crias-agent %s iniciando — stack=%s service=%s bind=%s:%d tls=%v",
		version, cfg.Server.Stack, cfg.Server.ServiceName,
		cfg.Agent.BindAddress, cfg.Agent.Port, cfg.Agent.TLSCert != "")

	// Inicializa componentes.
	rconClient := rcon.NewClient(
		cfg.Server.RCON.Host,
		cfg.Server.RCON.Port,
		cfg.Server.RCON.Password,
		cfg.Server.RCON.Enabled,
	)
	defer rconClient.Close()

	bus := events.NewBus()

	// GO-007: versão injetada via construtor para que StatusResponse.Version
	// reflita a versão real do build (não o default "dev").
	srv := server.New(cfg, rconClient, bus, version)

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

	// GO-004 + GO-006: opcional TLS/mTLS + interceptors de recovery custom.
	// Recovery é implementado inline (sem depender de google.golang.org/grpc/recovery
	// que foi movido para google.golang.org/grpc/interceptor/recovery em v1.65+).
	grpcOpts := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(
			recoveryUnaryInterceptor,
			server.AuthInterceptor(cfg.Agent.AuthToken),
		),
		grpc.ChainStreamInterceptor(
			recoveryStreamInterceptor,
			server.StreamAuthInterceptor(cfg.Agent.AuthToken),
		),
		grpc.MaxRecvMsgSize(64 * 1024),       // 64 KB por mensagem (comando RCON não precisa ser grande)
		grpc.MaxSendMsgSize(1 * 1024 * 1024), // 1 MB para stream de console
	}

	// GO-004: TLS/mTLS opcional. Obrigatório quando bind != loopback
	// (validado em config.Load — GO-005).
	// 2B-010: construímos tls.Config explicitamente com MinVersion TLS 1.2
	// em vez de usar credentials.NewServerTLSFromFile (que cria tls.Config{}
	// com MinVersion=0 e depende do default do Go, frágil a refactor futuro).
	if cfg.Agent.TLSCert != "" && cfg.Agent.TLSKey != "" {
		creds, err := loadTLSCreds(cfg.Agent.TLSCert, cfg.Agent.TLSKey)
		if err != nil {
			log.Fatalf("carregar TLS (%s, %s): %v", cfg.Agent.TLSCert, cfg.Agent.TLSKey, err)
		}
		grpcOpts = append(grpcOpts, grpc.Creds(creds))
		log.Printf("TLS habilitado: cert=%s", cfg.Agent.TLSCert)
	} else {
		// Loopback sem TLS — explicitamente marca como insecure credentials
		// para clareza (gRPC-Go vai warning se nenhuma Creds for setada em
		// versões futuras).
		grpcOpts = append(grpcOpts, grpc.Creds(insecure.NewCredentials()))
	}

	grpcSrv := grpc.NewServer(grpcOpts...)

	criasv1.RegisterServerControlServer(grpcSrv, srv)
	criasv1.RegisterEventBusServer(grpcSrv, srv)

	// Graceful shutdown.
	// GO-030: buffer 2 para não perder sinais em rajada; segundo sinal força
	// Stop() imediato (não-graceful).
	//
	// 2B-004: a goroutine do segundo-signal DEVE ser lançada ANTES de
	// GracefulStop(). Antes, ela era lançada depois — se GracefulStop
	// pendurava (e.g., stream hung), o segundo sinal nunca interrompia.
	// Agora lançamos um listener que fica pronto durante GracefulStop e
	// força Stop() quando chega o segundo sinal.
	go func() {
		sigCh := make(chan os.Signal, 2)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		defer signal.Stop(sigCh)

		sig := <-sigCh // primeiro sinal: graceful
		log.Printf("sinal %v recebido, parando graciosamente...", sig)
		cancel()

		// Lança um segundo listener ANTES de GracefulStop. Se GracefulStop
		// pendurar, o segundo sinal força Stop() imediato.
		secondSig := make(chan os.Signal, 1)
		signal.Notify(secondSig, syscall.SIGINT, syscall.SIGTERM)
		go func() {
			<-secondSig
			log.Printf("segundo sinal recebido, parando imediatamente...")
			grpcSrv.Stop()
		}()

		grpcSrv.GracefulStop()
		// GracefulStop retornou normalmente — limpa o segundo listener.
		signal.Stop(secondSig)
	}()

	log.Printf("servindo gRPC em %s", addr)
	// NÃO usar log.Fatalf aqui — ele chama os.Exit(1) e pula defer cancel()
	// e defer rconClient.Close(). Retornar normalmente garante cleanup.
	if err := grpcSrv.Serve(lis); err != nil {
		log.Printf("gRPC Serve falhou: %v", err)
		return
	}

	log.Printf("crias-agent finalizado")
}

// recoveryUnaryInterceptor recupera de panics em handlers gRPC unários.
// GO-006: previne que um panic derrube o processo inteiro; loga estruturado
// e retorna codes.Internal ao cliente.
// 2B-006: loga stack trace via runtime/debug.Stack() — sem isso, debugar
// panics em produção é praticamente impossível.
func recoveryUnaryInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("panic recuperado em handler gRPC unário %s: %v\n%s", info.FullMethod, p, debug.Stack())
			err = status.Errorf(codes.Internal, "erro interno do agente (panic recuperado)")
		}
	}()
	return handler(ctx, req)
}

// recoveryStreamInterceptor recupera de panics em handlers gRPC de stream.
// GO-006: análogo ao unário mas para streams (SubscribeEvents, StreamConsole).
// 2B-006: inclui stack trace.
func recoveryStreamInterceptor(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) (err error) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("panic recuperado em stream gRPC %s: %v\n%s", info.FullMethod, p, debug.Stack())
			err = status.Errorf(codes.Internal, "erro interno do agente (panic recuperado)")
		}
	}()
	return handler(srv, ss)
}

// loadTLSCreds carrega certificado/chave TLS do disco e retorna gRPC creds
// com tls.Config explícito (MinVersion TLS 1.2, cipher suites modernas).
// 2B-010: substitui credentials.NewServerTLSFromFile que dependia do
// default do Go para MinVersion (frágil a refactor futuro).
func loadTLSCreds(certFile, keyFile string) (credentials.TransportCredentials, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("load X509 keypair: %w", err)
	}
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12, // 2B-010: rejeita SSLv3/TLS 1.0/1.1 explicitamente
		ClientAuth:   tls.NoClientCert,
	}
	return credentials.NewTLS(tlsConfig), nil
}
