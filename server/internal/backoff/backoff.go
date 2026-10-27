// Package backoff is the per-account delay after a failed poll.
package backoff

import "time"

// Delay doubles the base interval for each consecutive failure, capped at maxDelay.
// The exponent itself is capped at 16 so the multiplication cannot overflow.
func Delay(base time.Duration, consecutiveFailures int, maxDelay time.Duration) time.Duration {
	if consecutiveFailures <= 0 {
		return base
	}
	exp := consecutiveFailures
	if exp > 16 {
		exp = 16
	}
	delay := base
	for i := 0; i < exp; i++ {
		if delay > maxDelay/2 {
			return maxDelay
		}
		delay *= 2
	}
	if delay > maxDelay {
		return maxDelay
	}
	return delay
}
