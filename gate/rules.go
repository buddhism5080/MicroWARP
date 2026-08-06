package main

import (
	"fmt"
	"strconv"
	"strings"
)

// Rule: host first, then status codes, then optional response text substring.
// Env PUNISH_RULES: rule;rule
// rule = host_pat|statuses|text
// host_pat: example.com | *.example.com | .example.com
// statuses: 429 | 403,429 | 400-499 | *   (empty statuses = no match)
// text: optional substring; empty = skip text check (status alone enough)
type Rule struct {
	HostPat  string
	Statuses []statusMatcher
	Text     string
	Raw      string
}

type statusMatcher struct {
	// if all is set, any status matches
	all bool
	// single code
	code int
	// range inclusive
	lo, hi int
	isRange bool
}

func parseRules(raw string) []Rule {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	var out []Rule
	for _, part := range strings.Split(raw, ";") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		// split into at most 3 fields by |
		fields := strings.SplitN(part, "|", 3)
		for len(fields) < 3 {
			fields = append(fields, "")
		}
		host := strings.TrimSpace(fields[0])
		if host == "" {
			continue
		}
		st := parseStatuses(strings.TrimSpace(fields[1]))
		if len(st) == 0 {
			continue
		}
		text := fields[2] // keep spaces inside text significant except outer trim
		text = strings.TrimSpace(text)
		out = append(out, Rule{
			HostPat:  host,
			Statuses: st,
			Text:     text,
			Raw:      part,
		})
	}
	return out
}

func parseStatuses(s string) []statusMatcher {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	var out []statusMatcher
	for _, p := range strings.Split(s, ",") {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if p == "*" {
			out = append(out, statusMatcher{all: true})
			continue
		}
		if strings.Contains(p, "-") {
			ab := strings.SplitN(p, "-", 2)
			lo, err1 := strconv.Atoi(strings.TrimSpace(ab[0]))
			hi, err2 := strconv.Atoi(strings.TrimSpace(ab[1]))
			if err1 != nil || err2 != nil || lo < 100 || hi > 599 || lo > hi {
				continue
			}
			out = append(out, statusMatcher{lo: lo, hi: hi, isRange: true})
			continue
		}
		code, err := strconv.Atoi(p)
		if err != nil || code < 100 || code > 599 {
			continue
		}
		out = append(out, statusMatcher{code: code})
	}
	return out
}

func hostMatches(pat, host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	pat = strings.ToLower(strings.TrimSpace(pat))
	if host == "" || pat == "" {
		return false
	}
	// strip brackets from IPv6 literals for safety; rules are hostname oriented
	host = strings.TrimPrefix(host, "[")
	host = strings.TrimSuffix(host, "]")

	if pat == "*" || pat == host {
		return true
	}
	if strings.HasPrefix(pat, "*.") {
		suf := pat[1:] // .example.com
		return strings.HasSuffix(host, suf) || host == strings.TrimPrefix(pat, "*.")
	}
	if strings.HasPrefix(pat, ".") {
		return strings.HasSuffix(host, pat) || host == strings.TrimPrefix(pat, ".")
	}
	return false
}

func statusMatches(ms []statusMatcher, code int) bool {
	for _, m := range ms {
		if m.all {
			return true
		}
		if m.isRange {
			if code >= m.lo && code <= m.hi {
				return true
			}
			continue
		}
		if m.code == code {
			return true
		}
	}
	return false
}

// MatchPunish evaluates rules in order.
//
// For each rule: host → status → optional text (all required layers on that rule).
// Semantics (first host hit wins):
//  1. Skip rules whose host pattern does not match.
//  2. On the first rule whose host matches, decide only with that rule:
//     - status (and text if set) match → punish
//     - otherwise → allow (do NOT try later rules)
//  3. If no rule host matches → allow.
func MatchPunish(rules []Rule, host string, status int, bodyPrefix string) (Rule, bool) {
	for _, r := range rules {
		if !hostMatches(r.HostPat, host) {
			continue
		}
		// First matching host: stop the rule list either way.
		if !statusMatches(r.Statuses, status) {
			return Rule{}, false
		}
		if r.Text != "" && !strings.Contains(bodyPrefix, r.Text) {
			return Rule{}, false
		}
		return r, true
	}
	return Rule{}, false
}

// HostNeedsMITM if any rule host pattern can match this host.
func HostNeedsMITM(rules []Rule, host string) bool {
	for _, r := range rules {
		if hostMatches(r.HostPat, host) {
			return true
		}
	}
	return false
}

func (r Rule) String() string {
	return fmt.Sprintf("%s", r.Raw)
}
