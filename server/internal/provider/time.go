package provider

import (
	"strings"
	"time"
)

// ParseTime parses ISO-8601 timestamps. Fractional seconds (Azure DevOps emits
// seven digits) are dropped before parsing.
func ParseTime(value string) (time.Time, bool) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, false
	}
	if dot := strings.IndexByte(value, '.'); dot >= 0 {
		end := dot
		for end < len(value) {
			c := value[end]
			if c == 'Z' || c == '+' || c == '-' {
				break
			}
			end++
		}
		value = value[:dot] + value[end:]
	}
	for _, layout := range []string{
		time.RFC3339,
		"2006-01-02T15:04:05Z07:00",
		"2006-01-02T15:04:05Z",
		"2006-01-02T15:04:05",
	} {
		if t, err := time.Parse(layout, value); err == nil {
			return t, true
		}
	}
	return time.Time{}, false
}
