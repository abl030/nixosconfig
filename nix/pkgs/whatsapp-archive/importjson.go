package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Shape of `wtsexporter -a -k <key> -b msgstore.db.crypt15 -j result.json`
// (Whatsapp_Chat_Exporter data_model.ChatStore / Message .to_json()).
type exportChat struct {
	Name     *string                  `json:"name"`
	Messages map[string]exportMessage `json:"messages"`
}

type exportMessage struct {
	FromMe    bool    `json:"from_me"`
	Timestamp float64 `json:"timestamp"`
	KeyID     any     `json:"key_id"`
	Data      *string `json:"data"`
	Caption   *string `json:"caption"`
	Media     bool    `json:"media"`
	Mime      *string `json:"mime"`
	Meta      bool    `json:"meta"`
	Sender    *string `json:"sender"`
	Reply     *string `json:"reply"`
	Sticker   bool    `json:"sticker"`
}

func str(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

// The exporter HTML-ises newlines; undo that for search.
func unhtml(s string) string {
	return strings.ReplaceAll(s, " <br>", "\n")
}

func kindForMime(mimeType string, sticker bool) string {
	switch {
	case sticker:
		return "sticker"
	case strings.HasPrefix(mimeType, "image/"):
		return "image"
	case strings.HasPrefix(mimeType, "video/"):
		return "video"
	case strings.HasPrefix(mimeType, "audio/"):
		return "audio"
	}
	return "document"
}

// runImportJSON merges a decrypted Android backup into the archive. Media paths
// in the JSON are relative to the directory wtsexporter ran in (baseDir); found
// files are copied into the media dir. Existing msg_ids are left untouched.
func runImportJSON(cfg Config, jsonPath, baseDir string) error {
	ctx := context.Background()
	arc, err := openArchive(archiveDB(cfg.DataDir))
	if err != nil {
		return err
	}
	f, err := os.Open(jsonPath)
	if err != nil {
		return err
	}
	defer f.Close()

	dec := json.NewDecoder(f)
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return fmt.Errorf("%s: expected a JSON object of chats", jsonPath)
	}
	// Batch commits (the pool is a single connection, so BEGIN/COMMIT on the
	// *sql.DB bind to it); per-row autocommit would fsync per message.
	if _, err := arc.db.Exec("BEGIN"); err != nil {
		return err
	}
	pending := 0
	var chats, added, seen, copied int
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return err
		}
		jid, _ := tok.(string)
		var chat exportChat
		if err := dec.Decode(&chat); err != nil {
			return fmt.Errorf("chat %s: %w", jid, err)
		}
		if jid == "" || strings.HasSuffix(jid, "@broadcast") || strings.HasSuffix(jid, "@newsletter") {
			continue
		}
		chats++
		isGroup := strings.HasSuffix(jid, "@g.us")
		if err := arc.UpsertChat(ctx, jid, str(chat.Name), isGroup); err != nil {
			return err
		}
		for _, m := range chat.Messages {
			keyID := fmt.Sprint(m.KeyID)
			if m.KeyID == nil || keyID == "" {
				continue
			}
			text := unhtml(str(m.Data))
			kind := "text"
			if m.Meta {
				if text == "" {
					continue
				}
				kind = "system"
			}
			msg := Msg{
				MsgID:      keyID,
				ChatJID:    jid,
				SenderName: str(m.Sender),
				FromMe:     m.FromMe,
				TS:         time.Unix(int64(m.Timestamp), 0),
				Kind:       kind,
				Text:       text,
				QuotedID:   str(m.Reply),
				Source:     "backup",
			}
			if !isGroup && !m.FromMe {
				msg.SenderJID = jid
			}
			if m.Media && !m.Meta {
				msg.Kind = kindForMime(str(m.Mime), m.Sticker)
				msg.MediaMime = str(m.Mime)
				msg.Text = unhtml(str(m.Caption))
				msg.MediaState = "missing"
				src := text
				if !filepath.IsAbs(src) {
					src = filepath.Join(baseDir, src)
				}
				rel := filepath.Join(msg.TS.UTC().Format("2006"), msg.TS.UTC().Format("01"), keyID+filepath.Ext(src))
				if err := copyFile(src, filepath.Join(cfg.MediaDir, rel)); err == nil {
					msg.MediaFile, msg.MediaState = rel, "ok"
					copied++
				}
			}
			ok, err := arc.InsertMessage(ctx, msg)
			if err != nil {
				return fmt.Errorf("insert %s: %w", keyID, err)
			}
			if ok {
				added++
			} else {
				seen++
			}
			if pending++; pending >= 2000 {
				if _, err := arc.db.Exec("COMMIT; BEGIN"); err != nil {
					return err
				}
				pending = 0
			}
		}
	}
	if _, err := arc.db.Exec("COMMIT"); err != nil {
		return err
	}
	_ = arc.SetMeta(ctx, "last_backup_import", time.Now().UTC().Format(time.RFC3339))
	log.Printf("import: %d chats, %d new messages, %d already archived, %d media files copied", chats, added, seen, copied)
	return nil
}

func copyFile(src, dst string) error {
	if _, err := os.Stat(dst); err == nil {
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o750); err != nil {
		return err
	}
	tmp := dst + ".part"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o640)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, dst)
}
