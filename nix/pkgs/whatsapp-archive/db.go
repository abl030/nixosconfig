package main

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

// The archive DB is separate from the whatsmeow session DB on purpose: the
// read-only MCP user gets read access to this file only, never to the session
// keys (which can act as the account). Rollback journal (not WAL) so a reader
// needs nothing but read permission on the file.
const schema = `
PRAGMA journal_mode=DELETE;
CREATE TABLE IF NOT EXISTS chats (
	jid        TEXT PRIMARY KEY,
	name       TEXT,
	is_group   INTEGER NOT NULL DEFAULT 0,
	updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS contacts (
	jid        TEXT PRIMARY KEY,
	name       TEXT,
	push_name  TEXT,
	updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
	id           INTEGER PRIMARY KEY,
	msg_id       TEXT NOT NULL UNIQUE,
	chat_jid     TEXT NOT NULL,
	sender_jid   TEXT,
	sender_name  TEXT,
	from_me      INTEGER NOT NULL,
	ts           INTEGER NOT NULL,
	kind         TEXT NOT NULL,
	text         TEXT,
	quoted_id    TEXT,
	media_mime   TEXT,
	media_file   TEXT,
	media_status TEXT,
	source       TEXT NOT NULL,
	edited_at    INTEGER,
	deleted_at   INTEGER
);
CREATE INDEX IF NOT EXISTS messages_chat_ts ON messages(chat_jid, ts);
CREATE INDEX IF NOT EXISTS messages_ts ON messages(ts);
CREATE TABLE IF NOT EXISTS message_edits (
	msg_id    TEXT NOT NULL,
	edited_at INTEGER NOT NULL,
	old_text  TEXT
);
CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
	text, content='messages', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
);
CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
	INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
	INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.id, old.text);
END;
CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF text ON messages BEGIN
	INSERT INTO messages_fts(messages_fts, rowid, text) VALUES ('delete', old.id, old.text);
	INSERT INTO messages_fts(rowid, text) VALUES (new.id, new.text);
END;
CREATE TABLE IF NOT EXISTS meta (
	key   TEXT PRIMARY KEY,
	value TEXT
);
`

type Archive struct {
	db *sql.DB
}

type Msg struct {
	MsgID      string
	ChatJID    string
	SenderJID  string
	SenderName string
	FromMe     bool
	TS         time.Time
	Kind       string
	Text       string
	QuotedID   string
	MediaMime  string
	MediaFile  string
	MediaState string
	Source     string
}

func openArchive(path string) (*Archive, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(10000)&_pragma=foreign_keys(1)")
	if err != nil {
		return nil, err
	}
	// One writer connection; SQLite serialises writes anyway.
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &Archive{db: db}, nil
}

func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// InsertMessage is append-only: an existing msg_id is never overwritten, so a
// live copy, a history-sync copy and a backup-import copy of one message merge.
// It reports whether a new row was written.
func (a *Archive) InsertMessage(ctx context.Context, m Msg) (bool, error) {
	res, err := a.db.ExecContext(ctx, `
		INSERT INTO messages (msg_id, chat_jid, sender_jid, sender_name, from_me, ts, kind,
			text, quoted_id, media_mime, media_file, media_status, source)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(msg_id) DO NOTHING`,
		m.MsgID, m.ChatJID, nullable(m.SenderJID), nullable(m.SenderName), m.FromMe, m.TS.Unix(), m.Kind,
		nullable(m.Text), nullable(m.QuotedID), nullable(m.MediaMime), nullable(m.MediaFile),
		nullable(m.MediaState), m.Source)
	if err != nil {
		return false, err
	}
	n, _ := res.RowsAffected()
	return n > 0, nil
}

func (a *Archive) SetMedia(ctx context.Context, msgID, file, state string) error {
	_, err := a.db.ExecContext(ctx,
		`UPDATE messages SET media_file = COALESCE(?, media_file), media_status = ? WHERE msg_id = ?`,
		nullable(file), state, msgID)
	return err
}

// RecordEdit keeps the previous text in message_edits before replacing it.
func (a *Archive) RecordEdit(ctx context.Context, msgID, newText string, at time.Time) error {
	tx, err := a.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx,
		`INSERT INTO message_edits (msg_id, edited_at, old_text) SELECT msg_id, ?, text FROM messages WHERE msg_id = ?`,
		at.Unix(), msgID); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx,
		`UPDATE messages SET text = ?, edited_at = ? WHERE msg_id = ?`, newText, at.Unix(), msgID); err != nil {
		return err
	}
	return tx.Commit()
}

// MarkDeleted records a revoke ("delete for everyone"); the content is kept.
func (a *Archive) MarkDeleted(ctx context.Context, msgID string, at time.Time) error {
	_, err := a.db.ExecContext(ctx,
		`UPDATE messages SET deleted_at = ? WHERE msg_id = ? AND deleted_at IS NULL`, at.Unix(), msgID)
	return err
}

func (a *Archive) UpsertChat(ctx context.Context, jid, name string, isGroup bool) error {
	_, err := a.db.ExecContext(ctx, `
		INSERT INTO chats (jid, name, is_group, updated_at) VALUES (?, ?, ?, ?)
		ON CONFLICT(jid) DO UPDATE SET
			name = COALESCE(excluded.name, chats.name),
			is_group = excluded.is_group,
			updated_at = excluded.updated_at`,
		jid, nullable(name), isGroup, time.Now().Unix())
	return err
}

func (a *Archive) UpsertContact(ctx context.Context, jid, name, pushName string) error {
	_, err := a.db.ExecContext(ctx, `
		INSERT INTO contacts (jid, name, push_name, updated_at) VALUES (?, ?, ?, ?)
		ON CONFLICT(jid) DO UPDATE SET
			name = COALESCE(excluded.name, contacts.name),
			push_name = COALESCE(excluded.push_name, contacts.push_name),
			updated_at = excluded.updated_at`,
		jid, nullable(name), nullable(pushName), time.Now().Unix())
	return err
}

func (a *Archive) ChatName(ctx context.Context, jid string) string {
	var name sql.NullString
	_ = a.db.QueryRowContext(ctx, `SELECT name FROM chats WHERE jid = ?`, jid).Scan(&name)
	return name.String
}

func (a *Archive) SetMeta(ctx context.Context, key, value string) error {
	_, err := a.db.ExecContext(ctx,
		`INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		key, value)
	return err
}
