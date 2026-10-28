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
		StickerPackMessage: &waE2E.StickerPackMessage{},
		MessageContextInfo: &waE2E.MessageContextInfo{},
	}
	if k, _, _, _, _ := describe(unknown); k != "" {
		t.Fatalf("expected no handler for sticker packs, got %q", k)
	}
	if got := unsupportedKind(unknown); got != "unsupported:stickerPackMessage" {
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

func TestDescribeWrappersAndBusiness(t *testing.T) {
	child := &waE2E.Message{AssociatedChildMessage: &waE2E.FutureProofMessage{Message: &waE2E.Message{
		ImageMessage: &waE2E.ImageMessage{Caption: proto.String("golf day"), Mimetype: proto.String("image/jpeg")},
	}}}
	kind, text, _, mimeType, dl := describe(child)
	if kind != "image" || text != "golf day" || mimeType != "image/jpeg" || dl == nil {
		t.Errorf("album child: %q %q %q dl=%v", kind, text, mimeType, dl != nil)
	}
	tpl := &waE2E.Message{TemplateMessage: &waE2E.TemplateMessage{HydratedTemplate: &waE2E.TemplateMessage_HydratedFourRowTemplate{
		HydratedContentText: proto.String("Your booking is confirmed"), HydratedFooterText: proto.String("Byrons"),
	}}}
	if kind, text, _, _, _ := describe(tpl); kind != "template" || text != "Your booking is confirmed\nByrons" {
		t.Errorf("template: %q %q", kind, text)
	}
	ph := &waE2E.Message{PlaceholderMessage: &waE2E.PlaceholderMessage{
		Type: waE2E.PlaceholderMessage_MASK_LINKED_DEVICES.Enum(),
	}}
	if kind, _, _, _, _ := describe(ph); kind != "placeholder" {
		t.Errorf("placeholder: %q", kind)
	}
	notice := &waE2E.Message{MessageHistoryNotice: &waE2E.MessageHistoryNotice{}}
	if k := unsupportedKind(notice); k != "" {
		t.Errorf("history notice should be non-content, got %q", k)
	}
}

func TestUnsupportedUpgrade(t *testing.T) {
	ctx := context.Background()
	arc, err := openArchive(filepath.Join(t.TempDir(), "archive.db"))
	if err != nil {
		t.Fatal(err)
	}
	unknown := &waE2E.Message{GroupMentionedMessage: &waE2E.FutureProofMessage{}}
	raw, _ := proto.Marshal(unknown)
	base := Msg{MsgID: "M1", ChatJID: "c@g.us", TS: time.Unix(1_700_000_000, 0), Source: "history"}

	u := base
	u.Kind, u.Raw = "unsupported:x", raw
	if ok, err := arc.InsertMessage(ctx, u); !ok || err != nil {
		t.Fatalf("insert unsupported: %v %v", ok, err)
	}
	rows, err := arc.UnsupportedRaw(ctx)
	if err != nil || len(rows) != 1 || string(rows[0].Raw) != string(raw) {
		t.Fatalf("raw kept: %v %d", err, len(rows))
	}
	// A replay that now understands the message upgrades the placeholder...
	h := base
	h.Kind, h.Text = "text", "now readable"
	if ok, err := arc.InsertMessage(ctx, h); !ok || err != nil {
		t.Fatalf("upgrade: %v %v", ok, err)
	}
	// ...but a handled row is never downgraded or overwritten.
	if ok, _ := arc.InsertMessage(ctx, u); ok {
		t.Error("handled row was downgraded")
	}
	other := base
	other.Kind, other.Text = "text", "different"
	if ok, _ := arc.InsertMessage(ctx, other); ok {
		t.Error("handled row was overwritten")
	}
	var kind, text string
	var rawLeft []byte
	_ = arc.db.QueryRow(`SELECT kind, text, raw FROM messages WHERE msg_id = 'M1'`).Scan(&kind, &text, &rawLeft)
	if kind != "text" || text != "now readable" || rawLeft != nil {
		t.Errorf("after upgrade: %q %q raw=%d", kind, text, len(rawLeft))
	}
	// The offline path used by reprocessUnsupported.
	u2 := base
	u2.MsgID, u2.Kind, u2.Raw = "M2", "unsupported:y", raw
	_, _ = arc.InsertMessage(ctx, u2)
	if err := arc.UpgradeUnsupported(ctx, "M2", Msg{Kind: "image", MediaState: "pending"}); err != nil {
		t.Fatal(err)
	}
	if rows, _ := arc.UnsupportedRaw(ctx); len(rows) != 0 {
		t.Errorf("%d unsupported rows left after upgrade", len(rows))
	}
}

func TestRawColumnMigration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "archive.db")
	old, err := openArchive(path)
	if err != nil {
		t.Fatal(err)
	}
	// Simulate the first-deploy schema, which had no raw column.
	if _, err := old.db.Exec(`ALTER TABLE messages DROP COLUMN raw`); err != nil {
		t.Fatal(err)
	}
	old.db.Close()
	arc, err := openArchive(path)
	if err != nil {
		t.Fatalf("reopen old schema: %v", err)
	}
	if _, err := arc.InsertMessage(context.Background(), Msg{MsgID: "X", ChatJID: "c", Kind: "unsupported:z", Raw: []byte{1}, Source: "live"}); err != nil {
		t.Fatalf("insert after migration: %v", err)
	}
}
