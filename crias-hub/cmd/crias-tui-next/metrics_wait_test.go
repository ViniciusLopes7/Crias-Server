package main

import (
	"context"
	"testing"
	"time"
)

func TestAwaitMetricsBatch(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	done := make(chan struct{})
	changed := make(chan struct{}, 1)
	changed <- struct{}{}
	// Once the first notification has been consumed, publish another
	// during the fixed window. The consumer sees one refresh for both.
	go func() {
		select {
		case changed <- struct{}{}:
		case <-ctx.Done():
		}
	}()
	if !awaitMetrics(ctx, done, changed, time.Second, metricsBatchWindow) {
		t.Fatal("no refresh")
	}
	if len(changed) != 0 {
		t.Fatal("pending burst not coalesced")
	}
	changed <- struct{}{}
	if !awaitMetrics(ctx, done, changed, time.Second, time.Millisecond) {
		t.Fatal("later notification lost")
	}
}

func TestAwaitMetricsFreshnessAndShutdown(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	changed := make(chan struct{}, 1)
	if !awaitMetrics(ctx, done, changed, time.Millisecond, time.Hour) {
		t.Fatal("freshness wake lost")
	}
	changed <- struct{}{}
	close(done)
	if awaitMetrics(ctx, done, changed, time.Hour, time.Hour) {
		t.Fatal("refresh after engine shutdown")
	}
	cancel()
	if awaitMetrics(ctx, make(chan struct{}), changed, time.Hour, time.Hour) {
		t.Fatal("refresh after cancellation")
	}
}
