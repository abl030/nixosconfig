package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The phone backup fills media into messages the live feed already archived
// (expired/skipped), never touches text rows, and maps wtsexporter's
// "The media is missing" marker to a media row rather than a system note.
func TestImportAttachesMediaToArchivedMessages(t *testing.T) {
	ctx := context.Background()
	dir := t.TempDir()
	cfg := Config{DataDir: filepath.Join(dir, "data"), MediaDir: filepath.Join(dir, "media")}
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		t.Fatal(err)
	}
	arc, err := openArchive(archiveDB(cfg.DataDir))
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(1_700_000_000, 0)
	for _, m := range []Msg{
		{MsgID: "IMG1", ChatJID: "a@s.whatsapp.net", TS: ts, Kind: "image", MediaMime: "image/jpeg", MediaState: "skipped", Source: "history"},
		{MsgID: "TXT1", ChatJID: "a@s.whatsapp.net", TS: ts, Kind: "text", Text: "hi", Source: "live"},
	} {
		if _, err := arc.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	arc.db.Close()

	// What wtsexporter writes: media paths under -m (here an absolute path).
	phoneMedia := filepath.Join(dir, "work", "Media", "WhatsApp Images")
	if err := os.MkdirAll(phoneMedia, 0o755); err != nil {
		t.Fatal(err)
	}
	img := filepath.Join(phoneMedia, "IMG-1.jpg")
	if err := os.WriteFile(img, []byte("jpeg"), 0o644); err != nil {
		t.Fatal(err)
	}
	result := filepath.Join(dir, "work", "result.json")
	json := `{"a@s.whatsapp.net": {"name": "A", "messages": {
	  "1": {"from_me": false, "timestamp": 1700000000, "key_id": "IMG1", "data": "` + img + `", "media": true, "mime": "image/jpeg", "meta": false},
	  "2": {"from_me": false, "timestamp": 1700000000, "key_id": "TXT1", "data": "` + img + `", "media": true, "mime": "image/jpeg", "meta": false},
	  "3": {"from_me": false, "timestamp": 1700000100, "key_id": "GONE", "data": "The media is missing", "media": true, "mime": "media", "meta": true, "caption": "beach"}
	}}}`
	if err := os.WriteFile(result, []byte(json), 0o600); err != nil {
		t.Fatal(err)
	}
	for range 2 { // idempotent re-run
		if err := runImportJSON(cfg, result, filepath.Join(dir, "work")); err != nil {
			t.Fatal(err)
		}
	}

	arc, err = openArchive(archiveDB(cfg.DataDir))
	if err != nil {
		t.Fatal(err)
	}
	check := func(id, wantKind, wantStatus string) {
		t.Helper()
		var kind string
		var status, file *string
		if err := arc.db.QueryRow(`SELECT kind, media_status, media_file FROM messages WHERE msg_id = ?`, id).Scan(&kind, &status, &file); err != nil {
			t.Fatalf("%s: %v", id, err)
		}
		got := ""
		if status != nil {
			got = *status
		}
		if kind != wantKind || got != wantStatus {
			t.Errorf("%s: kind=%q status=%q, want %q %q", id, kind, got, wantKind, wantStatus)
		}
		if wantStatus == "ok" {
			if file == nil {
				t.Fatalf("%s: no media_file", id)
			}
			if b, err := os.ReadFile(filepath.Join(cfg.MediaDir, *file)); err != nil || string(b) != "jpeg" {
				t.Errorf("%s: media copy %q: %v", id, *file, err)
			}
		}
	}
	check("IMG1", "image", "ok")      // skipped -> filled from the phone
	check("TXT1", "text", "")         // text row untouched
	check("GONE", "media", "missing") // not a system note
}
