// Package apierror defines a tiny typed error shared by domain services so
// the HTTP layer can tell "safe to show the client verbatim" input
// validation failures apart from opaque internal errors, whose raw message
// must never reach the client (spec §34.1 — don't leak internal detail; a
// database error message is not secret, but it isn't a contract either).
// Domain services only ever construct one of these for malformed input
// checked before any database access — never for a database or I/O
// failure — so httpapi can treat every other error as internal.
package apierror

type Validation struct{ Message string }

func (e *Validation) Error() string { return e.Message }

func NewValidation(message string) error { return &Validation{Message: message} }
