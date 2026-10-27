// Command pullwatchd polls GitHub and Azure DevOps and serves a small dashboard.
package main

import (
	"context"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/alessandro823/pullwatch/server/internal/app"
	"github.com/alessandro823/pullwatch/server/internal/config"
)

func main() {
	var (
		configPath = flag.String("config", env("PULLWATCH_CONFIG", "config.yaml"), "path to the YAML config")
		demo       = flag.Bool("demo", false, "serve sample data and do not poll")
		listen     = flag.String("listen", "", "address to listen on (overrides the config)")
	)
	flag.Parse()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var svc *app.Service
	if *demo {
		addr := *listen
		if addr == "" {
			addr = env("PULLWATCH_LISTEN", ":8080")
		}
		svc = app.Demo(addr)
		slog.Info("demo mode: sample data, no polling")
	} else {
		cfg, err := config.Load(*configPath)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pullwatchd: %v\n", err)
			os.Exit(1)
		}
		if *listen != "" {
			cfg.Listen = *listen
		}
		svc, err = app.Open(cfg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "pullwatchd: %v\n", err)
			os.Exit(1)
		}
	}
	if err := svc.Run(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "pullwatchd: %v\n", err)
		os.Exit(1)
	}
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
