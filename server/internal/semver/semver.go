// Package semver holds the small version helpers shared by detection, OSV and endoflife.
package semver

import (
	"strconv"
	"strings"
	"unicode"
)

// From returns the first number(.number)* in spec: "^17.2.0" → "17.2.0", "20-alpine" → "20".
func From(spec string) (string, bool) {
	start := -1
	for i, r := range spec {
		if unicode.IsDigit(r) {
			start = i
			break
		}
	}
	if start < 0 {
		return "", false
	}
	end := start
	seenDot := false
	for end < len(spec) {
		c := spec[end]
		if c >= '0' && c <= '9' {
			end++
			seenDot = false
			continue
		}
		if c == '.' && !seenDot && end+1 < len(spec) && spec[end+1] >= '0' && spec[end+1] <= '9' {
			seenDot = true
			end++
			continue
		}
		break
	}
	if end == start {
		return "", false
	}
	return spec[start:end], true
}

// Older reports whether a is a lower version than b. Missing components are 0.
// Non-numeric components compare as 0, matching the Mac app.
func Older(a, b string) bool {
	x := parts(a)
	y := parts(b)
	n := len(x)
	if len(y) > n {
		n = len(y)
	}
	for i := 0; i < n; i++ {
		l, r := 0, 0
		if i < len(x) {
			l = x[i]
		}
		if i < len(y) {
			r = y[i]
		}
		if l != r {
			return l < r
		}
	}
	return false
}

func parts(v string) []int {
	raw := strings.Split(v, ".")
	out := make([]int, len(raw))
	for i, p := range raw {
		n, err := strconv.Atoi(p)
		if err != nil {
			// Swift's Int() rejects the whole token ("0-rc1"), so junk becomes 0.
			out[i] = 0
			continue
		}
		out[i] = n
	}
	return out
}

// NumericCompare compares strings the way Finder/Swift `.numeric` does:
// digit runs compare as integers, everything else byte by byte.
func NumericCompare(a, b string) int {
	ia, ib := 0, 0
	for ia < len(a) && ib < len(b) {
		ca, cb := a[ia], b[ib]
		if isDigit(ca) && isDigit(cb) {
			ja := ia
			for ja < len(a) && isDigit(a[ja]) {
				ja++
			}
			jb := ib
			for jb < len(b) && isDigit(b[jb]) {
				jb++
			}
			na := strings.TrimLeft(a[ia:ja], "0")
			nb := strings.TrimLeft(b[ib:jb], "0")
			if na == "" {
				na = "0"
			}
			if nb == "" {
				nb = "0"
			}
			if len(na) != len(nb) {
				if len(na) < len(nb) {
					return -1
				}
				return 1
			}
			if na != nb {
				if na < nb {
					return -1
				}
				return 1
			}
			ia, ib = ja, jb
			continue
		}
		if ca != cb {
			if ca < cb {
				return -1
			}
			return 1
		}
		ia++
		ib++
	}
	switch {
	case ia < len(a):
		return 1
	case ib < len(b):
		return -1
	default:
		return 0
	}
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }
