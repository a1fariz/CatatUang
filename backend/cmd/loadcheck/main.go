package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"sort"
	"sync"
	"time"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run() error {
	target := flag.String("target", "http://127.0.0.1:8080/readyz", "Local health endpoint")
	requests := flag.Int("requests", 100, "Number of requests, 10–5000")
	concurrency := flag.Int("concurrency", 4, "Concurrent requests, 1–32")
	maxP95 := flag.Duration("max-p95", 500*time.Millisecond, "Fail if p95 exceeds this duration")
	flag.Parse()
	u, err := url.Parse(*target)
	if err != nil || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.Scheme != "http" && u.Scheme != "https" || net.ParseIP(u.Hostname()) == nil || !net.ParseIP(u.Hostname()).IsLoopback() || u.Path != "/readyz" && u.Path != "/healthz" && u.Path != "/v1" || *requests < 10 || *requests > 5000 || *concurrency < 1 || *concurrency > 32 || *maxP95 <= 0 {
		return errors.New("loadcheck requires a numeric loopback health URL and bounded request/concurrency values")
	}
	client := &http.Client{Timeout: 5 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	defer client.CloseIdleConnections()
	jobs := make(chan struct{})
	var wg sync.WaitGroup
	var mu sync.Mutex
	durations := make([]time.Duration, 0, *requests)
	failures := 0
	started := time.Now()
	for i := 0; i < *concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range jobs {
				start := time.Now()
				response, err := client.Get(*target)
				ok := err == nil
				if response != nil {
					_, readErr := io.Copy(io.Discard, io.LimitReader(response.Body, 1<<20))
					_ = response.Body.Close()
					ok = ok && response.StatusCode == 200 && readErr == nil
				}
				elapsed := time.Since(start)
				mu.Lock()
				durations = append(durations, elapsed)
				if !ok {
					failures++
				}
				mu.Unlock()
			}
		}()
	}
	for i := 0; i < *requests; i++ {
		jobs <- struct{}{}
	}
	close(jobs)
	wg.Wait()
	elapsed := time.Since(started)
	sort.Slice(durations, func(i, j int) bool { return durations[i] < durations[j] })
	percentile := func(p int) float64 {
		index := (*requests*p+99)/100 - 1
		return float64(durations[index].Microseconds()) / 1000
	}
	if err = json.NewEncoder(os.Stdout).Encode(map[string]any{"requests": *requests, "concurrency": *concurrency, "failures": failures, "elapsed_ms": float64(elapsed.Microseconds()) / 1000, "p50_ms": percentile(50), "p95_ms": percentile(95), "p99_ms": percentile(99)}); err != nil {
		return err
	}
	if failures > 0 || durations[(*requests*95+99)/100-1] > *maxP95 {
		return errors.New("local load acceptance threshold failed")
	}
	return nil
}
