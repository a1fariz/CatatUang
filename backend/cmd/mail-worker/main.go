package main

import (
	"catatuang/backend/internal/config"
	"catatuang/backend/internal/database"
	"catatuang/backend/internal/mailer"
	"catatuang/backend/internal/service"
	"context"
	"errors"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("mail worker stopped", "error", err.Error())
		os.Exit(1)
	}
}
func run(logger *slog.Logger) error {
	c, err := config.Load()
	if err != nil {
		return err
	}
	if len(c.Mail.Key) != 32 {
		return errors.New("mail settings required")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	pool, err := database.Open(ctx, c)
	if err != nil {
		return errors.New("mail database unavailable")
	}
	defer pool.Close()
	if err = database.CheckSchema(ctx, pool); err != nil {
		return errors.New("mail database schema not ready")
	}
	s := service.New(pool)
	if err = s.ConfigureMail(c.Mail.Key); err != nil {
		return err
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		claimCtx, cancel := context.WithTimeout(ctx, c.DBTimeout)
		message, claimErr := s.ClaimMail(claimCtx)
		cancel()
		if claimErr != nil && ctx.Err() == nil {
			logger.Warn("mail claim failed")
		}
		if message != nil {
			sendCtx, cancel := context.WithTimeout(ctx, 40*time.Second)
			sendErr := mailer.Send(sendCtx, c.Mail, *message)
			cancel()
			finishCtx, cancel := context.WithTimeout(context.Background(), c.DBTimeout)
			finishErr := s.FinishMail(finishCtx, *message, sendErr == nil)
			cancel()
			if sendErr != nil {
				logger.Warn("mail delivery failed", "job_id", message.ID)
			}
			if finishErr != nil {
				logger.Warn("mail completion persistence failed", "job_id", message.ID)
			}
			if ctx.Err() == nil {
				continue
			}
		}
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}
