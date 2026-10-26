package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"catatuang/backend/internal/config"
	"catatuang/backend/internal/database"
	"catatuang/backend/internal/httpapi"
	"catatuang/backend/internal/service"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("API stopped", "error", err.Error())
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	c, err := config.Load()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	pool, err := database.Open(ctx, c)
	if err != nil {
		return err
	}
	defer pool.Close()
	schemaCtx, cancel := context.WithTimeout(ctx, c.DBTimeout)
	err = database.CheckSchema(schemaCtx, pool)
	cancel()
	if err != nil {
		return errors.New("database schema check failed; run migrate up and check migration status")
	}
	ready := func(ctx context.Context) error {
		if err := pool.Ping(ctx); err != nil {
			return err
		}
		return database.CheckSchema(ctx, pool)
	}
	appService := service.New(pool)
	if len(c.Mail.Key) > 0 {
		if err = appService.ConfigureMail(c.Mail.Key); err != nil {
			return errors.New("mail configuration invalid")
		}
	}
	server := &http.Server{Addr: c.Address, Handler: httpapi.NewTrusted(logger, ready, c.DBTimeout, appService, c.TrustedProxies), ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, WriteTimeout: c.DBTimeout + 15*time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10}
	result := make(chan error, 1)
	go func() { result <- server.ListenAndServe() }()
	logger.Info("API starting", "address", c.Address, "environment", c.Environment)
	select {
	case err := <-result:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		logger.Info("API shutting down")
		shutdownCtx, cancel := context.WithTimeout(context.Background(), c.ShutdownTimeout)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			_ = server.Close()
			return errors.New("graceful shutdown exceeded deadline")
		}
		err := <-result
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}
