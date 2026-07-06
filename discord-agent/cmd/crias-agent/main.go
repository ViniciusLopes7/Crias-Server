// Crias agent entry point: loads config, starts gRPC server, runs monitors.
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

	rconClient := rcon.NewClient(
		cfg.Server.RCON.Host,
		cfg.Server.RCON.Port,
		cfg.Server.RCON.Password,
		cfg.Server.RCON.Enabled,
	)
	defer rconClient.Close()

	bus := events.NewBus()

	srv := server.New(cfg, rconClient, bus, version)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go srv.StartPlayerMonitor(ctx)
	go srv.StartHealthMonitor(ctx)
	go srv.StartAutoShutdownMonitor(ctx)

	addr := fmt.Sprintf("%s:%d", cfg.Agent.BindAddress, cfg.Agent.Port)
	lis, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("escutar %s: %v", addr, err)
	}

	// Recovery interceptors are inlined (grpc/recovery moved to grpc/interceptor/recovery in v1.65+).
	grpcOpts := []grpc.ServerOption{
		grpc.ChainUnaryInterceptor(
			recoveryUnaryInterceptor,
			server.AuthInterceptor(cfg.Agent.AuthToken),
		),
		grpc.ChainStreamInterceptor(
			recoveryStreamInterceptor,
			server.StreamAuthInterceptor(cfg.Agent.AuthToken),
		),
		grpc.MaxRecvMsgSize(64 * 1024),       // 64 KB per message (RCON commands are short)
		grpc.MaxSendMsgSize(1 * 1024 * 1024), // 1 MB for console stream
	}

	// TLS is required when bind != loopback (enforced in config.Load).
	// Explicit tls.Config with MinVersion TLS 1.2 avoids relying on Go's default.
	if cfg.Agent.TLSCert != "" && cfg.Agent.TLSKey != "" {
		creds, err := loadTLSCreds(cfg.Agent.TLSCert, cfg.Agent.TLSKey)
		if err != nil {
			log.Fatalf("carregar TLS (%s, %s): %v", cfg.Agent.TLSCert, cfg.Agent.TLSKey, err)
		}
		grpcOpts = append(grpcOpts, grpc.Creds(creds))
		log.Printf("TLS habilitado: cert=%s", cfg.Agent.TLSCert)
	} else {
		grpcOpts = append(grpcOpts, grpc.Creds(insecure.NewCredentials()))
	}

	grpcSrv := grpc.NewServer(grpcOpts...)

	criasv1.RegisterServerControlServer(grpcSrv, srv)
	criasv1.RegisterEventBusServer(grpcSrv, srv)

	// Graceful shutdown: first signal triggers GracefulStop, second forces Stop.
	// The second-signal listener is started BEFORE GracefulStop so a stuck
	// GracefulStop can still be interrupted.
	go func() {
		sigCh := make(chan os.Signal, 2)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		defer signal.Stop(sigCh)

		sig := <-sigCh
		log.Printf("sinal %v recebido, parando graciosamente...", sig)
		cancel()

		secondSig := make(chan os.Signal, 1)
		signal.Notify(secondSig, syscall.SIGINT, syscall.SIGTERM)
		go func() {
			<-secondSig
			log.Printf("segundo sinal recebido, parando imediatamente...")
			grpcSrv.Stop()
		}()

		grpcSrv.GracefulStop()
		signal.Stop(secondSig)
	}()

	log.Printf("servindo gRPC em %s", addr)
	// Do not use log.Fatalf here: os.Exit skips the deferred cancel() and rconClient.Close().
	if err := grpcSrv.Serve(lis); err != nil {
		log.Printf("gRPC Serve falhou: %v", err)
		return
	}

	log.Printf("crias-agent finalizado")
}

// recoveryUnaryInterceptor recovers from panics in unary handlers, logging the stack trace.
func recoveryUnaryInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("panic recuperado em handler gRPC unário %s: %v\n%s", info.FullMethod, p, debug.Stack())
			err = status.Errorf(codes.Internal, "erro interno do agente (panic recuperado)")
		}
	}()
	return handler(ctx, req)
}

// recoveryStreamInterceptor recovers from panics in stream handlers, logging the stack trace.
func recoveryStreamInterceptor(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) (err error) {
	defer func() {
		if p := recover(); p != nil {
			log.Printf("panic recuperado em stream gRPC %s: %v\n%s", info.FullMethod, p, debug.Stack())
			err = status.Errorf(codes.Internal, "erro interno do agente (panic recuperado)")
		}
	}()
	return handler(srv, ss)
}

// loadTLSCreds loads the TLS cert/key pair and returns gRPC credentials with MinVersion TLS 1.2.
func loadTLSCreds(certFile, keyFile string) (credentials.TransportCredentials, error) {
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil, fmt.Errorf("load X509 keypair: %w", err)
	}
	tlsConfig := &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
		ClientAuth:   tls.NoClientCert,
	}
	return credentials.NewTLS(tlsConfig), nil
}
