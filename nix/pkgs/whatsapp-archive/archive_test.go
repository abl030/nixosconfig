package main

import (
	"context"
	"crypto/sha256"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"google.golang.org/protobuf/proto"
)

func poll(name string, opts ...string) *waE2E.PollCreationMessage {
	p := &waE2E.PollCreationMessage{Name: proto.String(name)}
	for _, o := range opts {
		p.Options = append(p.Options, &waE2E.PollCreationMessage_Option{OptionName: proto.String(o)})
	}
	return p
}

func TestDescribePollVersions(t *testing.T) {
	for label, m := range map[string]*waE2E.Message{
		"v3": {PollCreationMessageV3: poll("Q?", "a", "b")},
		"v6": {PollCreationMessageV6: poll("Q?", "a", "b")},
		"v4": {PollCreationMessageV4: &waE2E.FutureProofMessage{Message: &waE2E.Message{PollCreationMessage: poll("Q?", "a", "b")}}},
	} {
		kind, text, _, _, _ := describe(m)
		if kind != "poll" || text != "Q?\n- a\n- b" {
			t.Errorf("%s: got %q %q", label, kind, text)
		}
		if got := pollOptions(pollOf(m)); strings.Join(got, ",") != "a,b" {
			t.Errorf("%s: options %v", label, got)
		}
	}
}

func TestDescribeEventAndUnsupported(t *testing.T) {
	kind, text, _, _, _ := describe(&waE2E.Message{EventMessage: &waE2E.EventMessage{
		Name: proto.String("Bucks golf"), Description: proto.String("bring clubs"),
	}})
	if kind != "event" || !strings.Contains(text, "Bucks golf") || !strings.Contains(text, "bring clubs") {
		t.Errorf("event: %q %q", kind, text)
	}
	unknown := &waE2E.Message{
		GroupInviteMessage: &waE2E.GroupInviteMessage{GroupName: proto.String("x")},
		MessageContextInfo: &waE2E.MessageContextInfo{},
	}
	if k, _, _, _, _ := describe(unknown); k != "" {
		t.Fatalf("expected no handler for group invite, got %q", k)
	}
	if got := unsupportedKind(unknown); got != "unsupported:groupInviteMessage" {
		t.Errorf("unsupported: %q", got)
	}
	keyOnly := &waE2E.Message{SenderKeyDistributionMessage: &waE2E.SenderKeyDistributionMessage{}}
	if got := unsupportedKind(keyOnly); got != "" {
		t.Errorf("key distribution must not be stored, got %q", got)
	}
}

func TestPollVotes(t *testing.T) {
	ctx := context.Background()
	arc, err := openArchive(filepath.Join(t.TempDir(), "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	if err := arc.SetMeta(ctx, "own_jid", "me@s.whatsapp.net"); err != nil {
		t.Fatal(err)
	}
	if err := arc.PutPollOptions(ctx, "P1", []string{"Golf", "Pub", "Both"}); err != nil {
		t.Fatal(err)
	}
	h := func(s string) []byte { sum := sha256.Sum256([]byte(s)); return sum[:] }
	t0 := time.Unix(1_700_000_000, 0)
	votes := []struct {
		voter string
		at    time.Time
		opts  [][]byte
	}{
		{"me@s.whatsapp.net", t0, [][]byte{h("Golf")}},
		{"bob@s.whatsapp.net", t0, [][]byte{h("Pub")}},
		{"bob@s.whatsapp.net", t0.Add(time.Hour), [][]byte{h("Golf"), h("Both")}}, // changed vote
		{"cat@s.whatsapp.net", t0, [][]byte{h("Pub")}},
		{"cat@s.whatsapp.net", t0.Add(time.Hour), nil}, // retracted
	}
	for _, v := range votes {
		if err := arc.RecordPollVote(ctx, "P1", v.voter, v.at, v.opts, "live"); err != nil {
			t.Fatal(err)
		}
	}
	// Replaying the same vote (history after live) must not duplicate it.
	if err := arc.RecordPollVote(ctx, "P1", "bob@s.whatsapp.net", t0.Add(time.Hour), [][]byte{h("Golf"), h("Both")}, "history"); err != nil {
		t.Fatal(err)
	}
	rows, err := arc.db.QueryContext(ctx, `SELECT option, votes, COALESCE(voters, '') FROM poll_results WHERE poll_msg_id = 'P1' ORDER BY idx`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var opt, voters string
		var n int
		if err := rows.Scan(&opt, &n, &voters); err != nil {
			t.Fatal(err)
		}
		// group_concat order is unspecified; compare voter sets.
		names := strings.Split(voters, ", ")
		sort.Strings(names)
		got = append(got, opt+"="+string(rune('0'+n))+"["+strings.Join(names, ", ")+"]")
	}
	want := []string{"Golf=2[bob, me]", "Pub=0[]", "Both=1[bob]"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("poll_results:\n got  %v\n want %v", got, want)
	}
	var logged int
	_ = arc.db.QueryRow(`SELECT count(*) FROM poll_votes`).Scan(&logged)
	if logged != 5 {
		t.Errorf("vote log rows = %d, want 5 (append-only, deduped)", logged)
	}
}
