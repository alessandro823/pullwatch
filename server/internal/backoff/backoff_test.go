package backoff

import (
	"testing"
	"time"
)

func TestDelayDoublesUntilTheCap(t *testing.T) {
	base := 2 * time.Minute
	max := 900 * time.Second
	if Delay(base, 0, max) != base {
		t.Fatal("no failures keeps the base interval")
	}
	if Delay(base, 1, max) != 4*time.Minute {
		t.Fatal("first failure doubles")
	}
	if Delay(base, 2, max) != 8*time.Minute {
		t.Fatal("second failure doubles again")
	}
	if Delay(base, 12, max) != max {
		t.Fatal("delay is capped")
	}
}
