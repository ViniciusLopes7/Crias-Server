package main

import (
	"context"
	"time"
)

const (
	metricsFreshnessWake = 2 * time.Second
	metricsBatchWindow   = 50 * time.Millisecond
)

// awaitMetrics batches notifications without extending the deadline when
// another collector publishes. The consumer snapshots after this returns;
// notifications arriving after the drain can trigger the next refresh.
func awaitMetrics(ctx context.Context, done, changed <-chan struct{}, freshness, batch time.Duration) bool {
	if ctx.Err() != nil {
		return false
	}
	wake := time.NewTimer(freshness)
	defer wake.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-done:
		return false
	case <-wake.C:
		return ctx.Err() == nil
	case <-changed:
	}
	group := time.NewTimer(batch)
	defer group.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-done:
		return false
	case <-group.C:
	}
	// Engine.Changed has capacity one; no unbounded drain under load.
	select {
	case <-changed:
	default:
	}
	return ctx.Err() == nil
}
