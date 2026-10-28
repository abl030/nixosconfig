package main

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
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
-- Votes reference options by SHA-256 of the option name, so options are kept
-- per poll to translate them. poll_votes is an append-only log (a changed or
-- retracted vote is a new row); poll_current_votes is the latest per voter.
CREATE TABLE IF NOT EXISTS poll_options (
	poll_msg_id TEXT NOT NULL,
	idx         INTEGER NOT NULL,
	name        TEXT NOT NULL,
	hash        TEXT NOT NULL,
	PRIMARY KEY (poll_msg_id, idx)
);
CREATE TABLE IF NOT EXISTS poll_votes (
	poll_msg_id TEXT NOT NULL,
	voter_jid   TEXT NOT NULL,
	ts          INTEGER NOT NULL,
	options     TEXT NOT NULL,
	source      TEXT NOT NULL,
	UNIQUE (poll_msg_id, voter_jid, ts)
);
CREATE VIEW IF NOT EXISTS poll_current_votes AS
	SELECT v.* FROM poll_votes v
	WHERE v.ts = (SELECT max(w.ts) FROM poll_votes w
	              WHERE w.poll_msg_id = v.poll_msg_id AND w.voter_jid = v.voter_jid);
CREATE VIEW IF NOT EXISTS poll_results AS
	SELECT o.poll_msg_id, o.idx, o.name AS option, count(cv.voter_jid) AS votes,
	       group_concat(CASE WHEN cv.voter_jid = (SELECT value FROM meta WHERE key = 'own_jid') THEN 'me'
	                         ELSE COALESCE(ct.name, ct.push_name, substr(cv.voter_jid, 1, instr(cv.voter_jid, '@') - 1)) END,
	                    ', ') AS voters
	FROM poll_options o
	LEFT JOIN poll_current_votes cv ON cv.poll_msg_id = o.poll_msg_id
	     AND EXISTS (SELECT 1 FROM json_each(cv.options) j WHERE j.value = o.name)
	LEFT JOIN contacts ct ON ct.jid = cv.voter_jid
	GROUP BY o.poll_msg_id, o.idx;
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
	Raw        []byte // only for unsupported:* kinds
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
	// Columns added after the first deploy (2026-10-28). raw holds the
	// protobuf of unsupported:* rows so a later handler can upgrade them in
	// place (reprocessUnsupported) without asking the phone for history again.
	var hasRaw int
	if err := db.QueryRow(`SELECT count(*) FROM pragma_table_info('messages') WHERE name = 'raw'`).Scan(&hasRaw); err != nil {
		return nil, err
	}
	if hasRaw == 0 {
		if _, err := db.Exec(`ALTER TABLE messages ADD COLUMN raw BLOB`); err != nil {
			return nil, fmt.Errorf("add raw column: %w", err)
		}
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
// The one exception is an unsupported:* placeholder row, which a handled copy
// replaces. It reports whether a row was written (new or upgraded).
func (a *Archive) InsertMessage(ctx context.Context, m Msg) (bool, error) {
	var raw any
	if len(m.Raw) > 0 {
		raw = m.Raw
	}
	res, err := a.db.ExecContext(ctx, `
		INSERT INTO messages (msg_id, chat_jid, sender_jid, sender_name, from_me, ts, kind,
			text, quoted_id, media_mime, media_file, media_status, source, raw)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(msg_id) DO UPDATE SET
			kind = excluded.kind, text = excluded.text, quoted_id = excluded.quoted_id,
			media_mime = excluded.media_mime, media_file = excluded.media_file,
			media_status = excluded.media_status, raw = NULL
		WHERE messages.kind LIKE 'unsupported:%' AND excluded.kind NOT LIKE 'unsupported:%'`,
		m.MsgID, m.ChatJID, nullable(m.SenderJID), nullable(m.SenderName), m.FromMe, m.TS.Unix(), m.Kind,
		nullable(m.Text), nullable(m.QuotedID), nullable(m.MediaMime), nullable(m.MediaFile),
		nullable(m.MediaState), m.Source, raw)
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

type rawRow struct {
	MsgID  string
	TS     time.Time
	Source string
	Raw    []byte
}

// UnsupportedRaw lists unsupported:* rows that kept their protobuf.
func (a *Archive) UnsupportedRaw(ctx context.Context) ([]rawRow, error) {
	rows, err := a.db.QueryContext(ctx,
		`SELECT msg_id, ts, source, raw FROM messages WHERE kind LIKE 'unsupported:%' AND raw IS NOT NULL`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []rawRow
	for rows.Next() {
		var r rawRow
		var ts int64
		if err := rows.Scan(&r.MsgID, &ts, &r.Source, &r.Raw); err != nil {
			return nil, err
		}
		r.TS = time.Unix(ts, 0)
		out = append(out, r)
	}
	return out, rows.Err()
}

// UpgradeUnsupported rewrites a placeholder row once a handler understands it.
func (a *Archive) UpgradeUnsupported(ctx context.Context, msgID string, m Msg) error {
	_, err := a.db.ExecContext(ctx, `
		UPDATE messages SET kind = ?, text = ?, quoted_id = ?, media_mime = ?, media_status = ?, raw = NULL
		WHERE msg_id = ? AND kind LIKE 'unsupported:%'`,
		m.Kind, nullable(m.Text), nullable(m.QuotedID), nullable(m.MediaMime), nullable(m.MediaState), msgID)
	return err
}

func (a *Archive) PutPollOptions(ctx context.Context, pollID string, names []string) error {
	for i, name := range names {
		sum := sha256.Sum256([]byte(name))
		if _, err := a.db.ExecContext(ctx,
			`INSERT INTO poll_options (poll_msg_id, idx, name, hash) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING`,
			pollID, i, name, hex.EncodeToString(sum[:])); err != nil {
			return err
		}
	}
	return nil
}

// RecordPollVote maps the selected option hashes to names (unknown hashes are
// kept as hex) and appends the vote. An empty selection is a retraction.
func (a *Archive) RecordPollVote(ctx context.Context, pollID, voter string, at time.Time, hashes [][]byte, source string) error {
	selected := make([]string, 0, len(hashes))
	for _, h := range hashes {
		hx := hex.EncodeToString(h)
		var name sql.NullString
		_ = a.db.QueryRowContext(ctx,
			`SELECT name FROM poll_options WHERE poll_msg_id = ? AND hash = ?`, pollID, hx).Scan(&name)
		if name.Valid {
			selected = append(selected, name.String)
		} else {
			selected = append(selected, "sha256:"+hx)
		}
	}
	opts, _ := json.Marshal(selected)
	_, err := a.db.ExecContext(ctx, `
		INSERT INTO poll_votes (poll_msg_id, voter_jid, ts, options, source) VALUES (?, ?, ?, ?, ?)
		ON CONFLICT DO NOTHING`, pollID, voter, at.Unix(), string(opts), source)
	return err
}

func (a *Archive) SetMeta(ctx context.Context, key, value string) error {
	_, err := a.db.ExecContext(ctx,
		`INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		key, value)
	return err
}
