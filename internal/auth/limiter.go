package auth

import (
	"sync"
	"time"
)

const (
	// maxLimiterEntries bounds the memory an attacker can make the server
	// hold by failing logins for a stream of distinct usernames or source
	// addresses. It is far above the product's target scale (≤5 users).
	maxLimiterEntries = 10_000
	// limiterIdleAfter is how long an unblocked entry with no new failures
	// is kept before it may be pruned to make room for a new one.
	limiterIdleAfter = 15 * time.Minute
)

// attemptLimiter is the process-local, in-memory login backoff tracker
// (spec §9.3 "rate limiting login"). It is keyed either by normalized
// username or by client address. A restart simply resets it rather than
// leaving anyone permanently locked out.
type attemptLimiter struct {
	mu      sync.Mutex
	entries map[string]*attemptEntry
	backoff func(consecutiveFailures int) time.Duration
	// maxInFlight caps concurrent attempts per key; 0 means unlimited. A
	// per-username cap of 1 stops a burst of parallel guesses from all
	// passing the backoff check before the first failure is recorded.
	maxInFlight int
}

type attemptEntry struct {
	consecutiveFailures int
	blockedUntil        time.Time
	lastFailure         time.Time
	inFlight            int
}

func newAttemptLimiter(backoff func(int) time.Duration, maxInFlight int) *attemptLimiter {
	return &attemptLimiter{entries: make(map[string]*attemptEntry), backoff: backoff, maxInFlight: maxInFlight}
}

// begin reserves an attempt for key. It never touches the database or
// Argon2id, so a blocked caller is rejected cheaply. Every successful begin
// must be paired with end. An empty key (an unknown client address) is
// never limited.
func (l *attemptLimiter) begin(key string, now time.Time) bool {
	if key == "" {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	entry := l.entries[key]
	// !Before rather than After: when the backoff is zero, blockedUntil
	// equals the failure's own timestamp, and the very next attempt (at the
	// same or a later time) must still be allowed.
	if entry != nil && now.Before(entry.blockedUntil) {
		return false
	}
	if entry != nil && l.maxInFlight > 0 && entry.inFlight >= l.maxInFlight {
		return false
	}
	if entry == nil {
		entry = &attemptEntry{}
		l.insert(key, entry, now)
	}
	entry.inFlight++
	return true
}

// end releases an attempt reserved by begin.
func (l *attemptLimiter) end(key string) {
	if key == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	entry := l.entries[key]
	if entry == nil {
		return
	}
	if entry.inFlight > 0 {
		entry.inFlight--
	}
	if entry.inFlight == 0 && entry.consecutiveFailures == 0 {
		delete(l.entries, key)
	}
}

func (l *attemptLimiter) recordFailure(key string, now time.Time) {
	if key == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	entry := l.entries[key]
	if entry == nil {
		entry = &attemptEntry{}
		l.insert(key, entry, now)
	}
	entry.consecutiveFailures++
	entry.lastFailure = now
	entry.blockedUntil = now.Add(l.backoff(entry.consecutiveFailures))
}

func (l *attemptLimiter) recordSuccess(key string) {
	if key == "" {
		return
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	entry := l.entries[key]
	if entry == nil {
		return
	}
	entry.consecutiveFailures = 0
	entry.blockedUntil = time.Time{}
	if entry.inFlight == 0 {
		delete(l.entries, key)
	}
}

// insert adds entry, first pruning idle entries (and, if that is not
// enough, the least recently failed idle one) when the table is full.
// Callers hold l.mu.
func (l *attemptLimiter) insert(key string, entry *attemptEntry, now time.Time) {
	if len(l.entries) >= maxLimiterEntries {
		var oldestKey string
		var oldest time.Time
		for k, e := range l.entries {
			if e.inFlight > 0 || now.Before(e.blockedUntil) {
				continue
			}
			if now.Sub(e.lastFailure) > limiterIdleAfter {
				delete(l.entries, k)
				continue
			}
			if oldestKey == "" || e.lastFailure.Before(oldest) {
				oldestKey, oldest = k, e.lastFailure
			}
		}
		if len(l.entries) >= maxLimiterEntries && oldestKey != "" {
			delete(l.entries, oldestKey)
		}
	}
	l.entries[key] = entry
}

func (l *attemptLimiter) size() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.entries)
}

// loginBackoff grows with consecutive failures for one username: harmless
// for a genuine typo (the first couple of attempts are unthrottled) while
// making sustained password guessing increasingly expensive in wall-clock
// time on top of Argon2id's own per-attempt cost.
func loginBackoff(consecutiveFailures int) time.Duration {
	switch {
	case consecutiveFailures < 3:
		return 0
	case consecutiveFailures < 5:
		return time.Second
	case consecutiveFailures < 8:
		return 10 * time.Second
	default:
		return time.Minute
	}
}

// addressBackoff throttles one client address that fails logins across
// many usernames (password spraying). It is more lenient than the
// per-username backoff because a family may share one NAT address.
func addressBackoff(consecutiveFailures int) time.Duration {
	switch {
	case consecutiveFailures < 10:
		return 0
	case consecutiveFailures < 20:
		return 5 * time.Second
	case consecutiveFailures < 40:
		return 30 * time.Second
	default:
		return 5 * time.Minute
	}
}
