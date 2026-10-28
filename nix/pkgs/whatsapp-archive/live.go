package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// Exit codes systemd must NOT restart on (RestartPreventExitStatus): the
// condition needs a human (re-link) or a code bump (outdated client).
const (
	exitLoggedOut = 3
	exitOutdated  = 4
	exitTempBan   = 5
)

type Config struct {
	DataDir          string
	MediaDir         string
	HealthAddr       string
	HistoryMediaDays int
}

func sessionDB(dataDir string) string {
	return filepath.Join(dataDir, "session", "session.db")
}

func archiveDB(dataDir string) string {
	return filepath.Join(dataDir, "archive.db")
}

func init() {
	// Shows as the linked device's name on the phone. Ask for the full
	// history on link (the phone still caps how much it sends).
	store.DeviceProps.Os = proto.String("homelab-archive")
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_DESKTOP.Enum()
	store.DeviceProps.RequireFullSync = proto.Bool(true)
}

func openDevice(ctx context.Context, dataDir string) (*sqlstore.Container, *store.Device, error) {
	if err := os.MkdirAll(filepath.Join(dataDir, "session"), 0o700); err != nil {
		return nil, nil, err
	}
	container, err := sqlstore.New(ctx, "sqlite",
		"file:"+sessionDB(dataDir)+"?_pragma=foreign_keys(1)&_pragma=busy_timeout(10000)",
		waLog.Stdout("store", "WARN", false))
	if err != nil {
		return nil, nil, err
	}
	device, err := container.GetFirstDevice(ctx)
	if err != nil {
		return nil, nil, err
	}
	return container, device, nil
}

type archiver struct {
	cfg     Config
	cli     *whatsmeow.Client
	arc     *Archive
	media   chan mediaJob
	groups  sync.Map // chat jid -> struct{} once the group name is fetched
	healthy atomic.Bool
	exit    chan int

	unsupported sync.Map  // unsupported kind -> struct{}, to log each once
	reprocessed sync.Once // reprocessUnsupported on the first connect
}

type mediaJob struct {
	msgID string
	ts    time.Time
	mime  string
	dl    whatsmeow.DownloadableMessage
}

// newArchiver wires the archive handler onto a client. Used by both the daemon
// and link, so history pushed by the phone during pairing is stored, not lost.
func newArchiver(cfg Config, device *store.Device) (*archiver, error) {
	arc, err := openArchive(archiveDB(cfg.DataDir))
	if err != nil {
		return nil, err
	}
	a := &archiver{
		cfg:   cfg,
		cli:   whatsmeow.NewClient(device, waLog.Stdout("client", "WARN", false)),
		arc:   arc,
		media: make(chan mediaJob, 4096),
		exit:  make(chan int, 1),
	}
	a.cli.EnableAutoReconnect = true
	// Ack only after our handler has written the message: a crash mid-write
	// makes the server redeliver instead of losing it.
	a.cli.SynchronousAck = true
	a.cli.AddEventHandler(a.handle)
	for range 2 {
		go a.mediaWorker()
	}
	return a, nil
}

func runDaemon(cfg Config) error {
	ctx := context.Background()
	_, device, err := openDevice(ctx, cfg.DataDir)
	if err != nil {
		return err
	}
	if device.ID == nil {
		log.Printf("not linked: run whatsapp-archive-link first")
		os.Exit(exitLoggedOut)
	}
	a, err := newArchiver(cfg, device)
	if err != nil {
		return err
	}
	go a.serveHealth()

	if err := a.cli.Connect(); err != nil {
		return fmt.Errorf("connect: %w", err)
	}
	code := <-a.exit
	a.cli.Disconnect()
	os.Exit(code)
	return nil
}

func (a *archiver) serveHealth() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		if a.healthy.Load() && a.cli.IsConnected() && a.cli.IsLoggedIn() {
			fmt.Fprintln(w, `{"healthy":true}`)
			return
		}
		w.WriteHeader(http.StatusServiceUnavailable)
		fmt.Fprintln(w, `{"healthy":false}`)
	})
	if err := http.ListenAndServe(a.cfg.HealthAddr, mux); err != nil {
		log.Printf("health server: %v", err)
	}
}

func (a *archiver) handle(evt any) {
	ctx := context.Background()
	switch e := evt.(type) {
	case *events.Connected:
		a.healthy.Store(true)
		_ = a.arc.SetMeta(ctx, "last_connected", time.Now().UTC().Format(time.RFC3339))
		_ = a.arc.SetMeta(ctx, "logged_out", "")
		_ = a.arc.SetMeta(ctx, "own_jid", a.normJID(ctx, a.cli.Store.GetJID()).String())
		log.Printf("connected")
		a.reprocessed.Do(func() { go a.reprocessUnsupported(context.Background()) })
	case *events.Disconnected:
		a.healthy.Store(false)
		log.Printf("disconnected; auto-reconnecting")
	case *events.LoggedOut:
		a.healthy.Store(false)
		_ = a.arc.SetMeta(ctx, "logged_out", time.Now().UTC().Format(time.RFC3339))
		log.Printf("LOGGED OUT (reason %v): re-link with whatsapp-archive-link", e.Reason)
		a.exit <- exitLoggedOut
	case *events.ClientOutdated:
		log.Printf("CLIENT OUTDATED: bump whatsmeow (scripts/update_whatsapp_archive.sh)")
		a.exit <- exitOutdated
	case *events.TemporaryBan:
		log.Printf("TEMPORARY BAN: %v (expires in %v); not reconnecting", e.Code, e.Expire)
		a.exit <- exitTempBan
	case *events.StreamReplaced:
		log.Printf("stream replaced by another connection with the same session")
		a.exit <- 1
	case *events.Message:
		a.storeMessage(ctx, e, "live")
	case *events.HistorySync:
		a.storeHistory(ctx, e)
	case *events.PushName:
		_ = a.arc.UpsertContact(ctx, a.normJID(ctx, e.JID).String(), "", e.NewPushName)
	case *events.Contact:
		_ = a.arc.UpsertContact(ctx, a.normJID(ctx, e.JID).String(), e.Action.GetFullName(), "")
	case *events.AppStateSyncComplete:
		a.syncContacts(ctx)
	}
}

// normJID maps a LID (hidden-user) JID to the phone-number JID when known, so
// the live feed and the Android backup import agree on chat keys.
func (a *archiver) normJID(ctx context.Context, j types.JID) types.JID {
	j = j.ToNonAD()
	if j.Server == types.HiddenUserServer {
		if pn, err := a.cli.Store.LIDs.GetPNForLID(ctx, j); err == nil && !pn.IsEmpty() {
			return pn.ToNonAD()
		}
	}
	return j
}

func (a *archiver) syncContacts(ctx context.Context) {
	all, err := a.cli.Store.Contacts.GetAllContacts(ctx)
	if err != nil {
		log.Printf("contacts: %v", err)
		return
	}
	for jid, c := range all {
		name := c.FullName
		if name == "" {
			name = c.BusinessName
		}
		_ = a.arc.UpsertContact(ctx, a.normJID(ctx, jid).String(), name, c.PushName)
	}
}

func (a *archiver) ensureChat(ctx context.Context, chat types.JID, isGroup bool) {
	if !isGroup {
		_ = a.arc.UpsertChat(ctx, chat.String(), "", false)
		return
	}
	if _, done := a.groups.LoadOrStore(chat.String(), struct{}{}); done {
		return
	}
	name := ""
	if info, err := a.cli.GetGroupInfo(ctx, chat); err == nil {
		name = info.Name
	}
	_ = a.arc.UpsertChat(ctx, chat.String(), name, true)
}

func skipChat(chat types.JID) bool {
	// Status stories and channels are not personal correspondence.
	return chat == types.StatusBroadcastJID || chat.Server == types.NewsletterServer
}

func (a *archiver) storeMessage(ctx context.Context, evt *events.Message, source string) {
	info := evt.Info
	if skipChat(info.Chat) || evt.Message == nil {
		return
	}
	chat := a.normJID(ctx, info.Chat)
	sender := a.normJID(ctx, info.Sender)

	if pm := evt.Message.GetProtocolMessage(); pm != nil {
		target := pm.GetKey().GetID()
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			if err := a.arc.MarkDeleted(ctx, target, info.Timestamp); err != nil {
				log.Printf("revoke %s: %v", target, err)
			}
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			kind, text, _, _, _ := describe(pm.GetEditedMessage())
			if kind != "" {
				if err := a.arc.RecordEdit(ctx, target, text, info.Timestamp); err != nil {
					log.Printf("edit %s: %v", target, err)
				}
			}
		}
		return
	}

	if evt.Message.GetPollUpdateMessage() != nil {
		a.storeLiveVote(ctx, evt, sender)
		return
	}

	kind, text, quoted, mimeType, dl := describe(evt.Message)
	var raw []byte
	if kind == "" {
		kind = unsupportedKind(evt.Message)
		if kind == "" {
			return // key distribution, app-state and other non-content messages
		}
		// Keep the protobuf so a later handler can upgrade the row in place.
		raw, _ = proto.Marshal(evt.Message)
		if _, seen := a.unsupported.LoadOrStore(kind, struct{}{}); !seen {
			log.Printf("storing %s messages as raw placeholders (no handler yet), e.g. %s", kind, info.ID)
		}
	}
	a.ensureChat(ctx, chat, info.IsGroup)

	m := Msg{
		MsgID:     info.ID,
		ChatJID:   chat.String(),
		SenderJID: sender.String(),
		FromMe:    info.IsFromMe,
		TS:        info.Timestamp,
		Kind:      kind,
		Text:      text,
		QuotedID:  quoted,
		MediaMime: mimeType,
		Source:    source,
		Raw:       raw,
	}
	if !info.IsFromMe {
		m.SenderName = info.PushName
	}
	if dl != nil {
		m.MediaState = "pending"
	}
	added, err := a.arc.InsertMessage(ctx, m)
	if err != nil {
		// Panicking here would skip the ack, so the server redelivers.
		log.Printf("insert %s: %v", info.ID, err)
		return
	}
	// Even for an already-archived poll: backfills options for polls stored
	// before options were recorded.
	if p := pollOf(evt.Message); p != nil {
		if err := a.arc.PutPollOptions(ctx, info.ID, pollOptions(p)); err != nil {
			log.Printf("poll options %s: %v", info.ID, err)
		}
	}
	if web := evt.SourceWebMsg; web != nil {
		a.storeHistoryVotes(ctx, info.ID, chat, web.GetPollUpdates())
	}
	if added && dl != nil {
		a.queueMedia(ctx, info.ID, info.Timestamp, source, mimeType, dl)
	}
}

func (a *archiver) queueMedia(ctx context.Context, msgID string, ts time.Time, source, mimeType string, dl whatsmeow.DownloadableMessage) {
	if source != "live" && time.Since(ts) > time.Duration(a.cfg.HistoryMediaDays)*24*time.Hour {
		// Old history media is long gone from the CDN; the backup import has it.
		_ = a.arc.SetMedia(ctx, msgID, "", "skipped")
		return
	}
	select {
	case a.media <- mediaJob{msgID: msgID, ts: ts, mime: mimeType, dl: dl}:
	default:
		_ = a.arc.SetMedia(ctx, msgID, "", "queue-full")
	}
}

// reprocessUnsupported upgrades unsupported:* rows whose kept protobuf a
// newer describe() now understands. Runs once per daemon start.
func (a *archiver) reprocessUnsupported(ctx context.Context) {
	rows, err := a.arc.UnsupportedRaw(ctx)
	if err != nil {
		log.Printf("reprocess: %v", err)
		return
	}
	upgraded := 0
	for _, r := range rows {
		var msg waE2E.Message
		if err := proto.Unmarshal(r.Raw, &msg); err != nil {
			continue
		}
		kind, text, quoted, mimeType, dl := describe(&msg)
		if kind == "" {
			continue
		}
		m := Msg{Kind: kind, Text: text, QuotedID: quoted, MediaMime: mimeType}
		if dl != nil {
			m.MediaState = "pending"
		}
		if err := a.arc.UpgradeUnsupported(ctx, r.MsgID, m); err != nil {
			log.Printf("reprocess %s: %v", r.MsgID, err)
			continue
		}
		upgraded++
		if dl != nil {
			a.queueMedia(ctx, r.MsgID, r.TS, r.Source, mimeType, dl)
		}
	}
	if len(rows) > 0 {
		log.Printf("reprocess: upgraded %d of %d unsupported rows", upgraded, len(rows))
	}
}

// storeLiveVote decrypts a vote with the poll's message secret (whatsmeow
// keeps secrets for live and history-synced polls).
func (a *archiver) storeLiveVote(ctx context.Context, evt *events.Message, voter types.JID) {
	pollID := evt.Message.GetPollUpdateMessage().GetPollCreationMessageKey().GetID()
	vote, err := a.cli.DecryptPollVote(ctx, evt)
	if err != nil {
		log.Printf("poll vote %s on %s: %v", evt.Info.ID, pollID, err)
		return
	}
	if err := a.arc.RecordPollVote(ctx, pollID, voter.String(), evt.Info.Timestamp, vote.GetSelectedOptions(), "live"); err != nil {
		log.Printf("poll vote %s: %v", evt.Info.ID, err)
	}
}

// storeHistoryVotes records the (already decrypted) votes a history sync
// attaches to a poll message.
func (a *archiver) storeHistoryVotes(ctx context.Context, pollID string, chat types.JID, updates []*waWeb.PollUpdate) {
	for _, u := range updates {
		key := u.GetPollUpdateMessageKey()
		var voter types.JID
		switch {
		case key.GetFromMe():
			voter = a.cli.Store.GetJID()
		case key.GetParticipant() != "":
			voter, _ = types.ParseJID(key.GetParticipant())
		default:
			voter = chat
		}
		voter = a.normJID(ctx, voter)
		at := time.UnixMilli(u.GetSenderTimestampMS())
		if err := a.arc.RecordPollVote(ctx, pollID, voter.String(), at, u.GetVote().GetSelectedOptions(), "history"); err != nil {
			log.Printf("history vote on %s: %v", pollID, err)
		}
	}
}

func (a *archiver) storeHistory(ctx context.Context, evt *events.HistorySync) {
	data := evt.Data
	for _, pn := range data.GetPushnames() {
		if j, err := types.ParseJID(pn.GetID()); err == nil {
			_ = a.arc.UpsertContact(ctx, a.normJID(ctx, j).String(), "", pn.GetPushname())
		}
	}
	n := 0
	for _, conv := range data.GetConversations() {
		chat, err := types.ParseJID(conv.GetID())
		if err != nil || skipChat(chat) {
			continue
		}
		if name := conv.GetName(); name != "" {
			_ = a.arc.UpsertChat(ctx, a.normJID(ctx, chat).String(), name, chat.Server == types.GroupServer)
		}
		for _, hm := range conv.GetMessages() {
			parsed, err := a.cli.ParseWebMessage(chat, hm.GetMessage())
			if err != nil {
				continue
			}
			a.storeMessage(ctx, parsed, "history")
			n++
		}
	}
	log.Printf("history sync %v: %d conversations, %d messages", data.GetSyncType(), len(data.GetConversations()), n)
}

func (a *archiver) mediaWorker() {
	for job := range a.media {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		data, err := a.cli.Download(ctx, job.dl)
		cancel()
		state := "ok"
		rel := ""
		switch {
		case err != nil && (errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith404) ||
			errors.Is(err, whatsmeow.ErrMediaDownloadFailedWith410) ||
			errors.Is(err, whatsmeow.ErrNoURLPresent)):
			state = "expired"
		case err != nil:
			state = "failed"
			log.Printf("media %s: %v", job.msgID, err)
		default:
			rel = filepath.Join(job.ts.UTC().Format("2006"), job.ts.UTC().Format("01"), job.msgID+extFor(job.mime))
			if werr := writeFile(filepath.Join(a.cfg.MediaDir, rel), data); werr != nil {
				state, rel = "failed", ""
				log.Printf("media write %s: %v", job.msgID, werr)
			}
		}
		_ = a.arc.SetMedia(context.Background(), job.msgID, rel, state)
	}
}

func extFor(mimeType string) string {
	base, _, _ := strings.Cut(mimeType, ";")
	switch base {
	case "image/jpeg":
		return ".jpg"
	case "audio/ogg":
		return ".ogg"
	case "video/mp4":
		return ".mp4"
	case "image/webp":
		return ".webp"
	}
	if exts, _ := mime.ExtensionsByType(base); len(exts) > 0 {
		return exts[0]
	}
	return ".bin"
}

func writeFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o750); err != nil {
		return err
	}
	tmp := path + ".part"
	if err := os.WriteFile(tmp, data, 0o640); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// describe flattens the WhatsApp message union into (kind, searchable text,
// quoted message id, media mime, downloadable). kind "" means "not content".
func describe(m *waE2E.Message) (string, string, string, string, whatsmeow.DownloadableMessage) {
	if m == nil {
		return "", "", "", "", nil
	}
	switch {
	case m.Conversation != nil:
		return "text", m.GetConversation(), "", "", nil
	case m.ExtendedTextMessage != nil:
		x := m.GetExtendedTextMessage()
		return "text", x.GetText(), x.GetContextInfo().GetStanzaID(), "", nil
	case m.ImageMessage != nil:
		x := m.GetImageMessage()
		return "image", x.GetCaption(), x.GetContextInfo().GetStanzaID(), x.GetMimetype(), x
	case m.VideoMessage != nil:
		x := m.GetVideoMessage()
		return "video", x.GetCaption(), x.GetContextInfo().GetStanzaID(), x.GetMimetype(), x
	case m.AudioMessage != nil:
		x := m.GetAudioMessage()
		kind := "audio"
		if x.GetPTT() {
			kind = "voice"
		}
		return kind, "", x.GetContextInfo().GetStanzaID(), x.GetMimetype(), x
	case m.DocumentMessage != nil:
		x := m.GetDocumentMessage()
		text := strings.TrimSpace(x.GetFileName() + "\n" + x.GetCaption())
		return "document", text, x.GetContextInfo().GetStanzaID(), x.GetMimetype(), x
	case m.StickerMessage != nil:
		x := m.GetStickerMessage()
		return "sticker", "", x.GetContextInfo().GetStanzaID(), x.GetMimetype(), x
	case m.LocationMessage != nil:
		x := m.GetLocationMessage()
		text := strings.TrimSpace(fmt.Sprintf("%s %s (%.6f, %.6f)", x.GetName(), x.GetAddress(),
			x.GetDegreesLatitude(), x.GetDegreesLongitude()))
		return "location", text, x.GetContextInfo().GetStanzaID(), "", nil
	case m.LiveLocationMessage != nil:
		x := m.GetLiveLocationMessage()
		return "location", fmt.Sprintf("live location (%.6f, %.6f) %s",
			x.GetDegreesLatitude(), x.GetDegreesLongitude(), x.GetCaption()), "", "", nil
	case m.ContactMessage != nil:
		x := m.GetContactMessage()
		return "contact", x.GetDisplayName() + "\n" + x.GetVcard(), "", "", nil
	case m.ContactsArrayMessage != nil:
		var parts []string
		for _, c := range m.GetContactsArrayMessage().GetContacts() {
			parts = append(parts, c.GetDisplayName())
		}
		return "contact", strings.Join(parts, ", "), "", "", nil
	case m.ReactionMessage != nil:
		x := m.GetReactionMessage()
		return "reaction", x.GetText(), x.GetKey().GetID(), "", nil
	case pollOf(m) != nil:
		x := pollOf(m)
		lines := []string{x.GetName()}
		for _, o := range pollOptions(x) {
			lines = append(lines, "- "+o)
		}
		return "poll", strings.Join(lines, "\n"), x.GetContextInfo().GetStanzaID(), "", nil
	case m.PollResultSnapshotMessage != nil || m.PollResultSnapshotMessageV3 != nil:
		x := m.GetPollResultSnapshotMessage()
		if x == nil {
			x = m.GetPollResultSnapshotMessageV3()
		}
		lines := []string{x.GetName()}
		for _, v := range x.GetPollVotes() {
			lines = append(lines, fmt.Sprintf("- %s: %d", v.GetOptionName(), v.GetOptionVoteCount()))
		}
		return "poll-result", strings.Join(lines, "\n"), "", "", nil
	case m.EventMessage != nil:
		x := m.GetEventMessage()
		lines := []string{x.GetName()}
		if x.GetStartTime() != 0 {
			when := time.Unix(x.GetStartTime(), 0).Local().Format("Mon 2 Jan 2006 15:04")
			if x.GetEndTime() != 0 {
				when += " – " + time.Unix(x.GetEndTime(), 0).Local().Format("Mon 2 Jan 2006 15:04")
			}
			lines = append(lines, "When: "+when)
		}
		if loc := x.GetLocation(); loc != nil {
			lines = append(lines, strings.TrimSpace("Where: "+loc.GetName()+" "+loc.GetAddress()))
		}
		if x.GetDescription() != "" {
			lines = append(lines, x.GetDescription())
		}
		if x.GetIsCanceled() {
			lines = append(lines, "(cancelled)")
		}
		return "event", strings.Join(lines, "\n"), x.GetContextInfo().GetStanzaID(), "", nil
	case m.PtvMessage != nil:
		x := m.GetPtvMessage()
		return "video-note", x.GetCaption(), x.GetContextInfo().GetStanzaID(), x.GetMimetype(), x
	case m.AlbumMessage != nil:
		// The photos follow as their own (associatedChild-wrapped) messages.
		x := m.GetAlbumMessage()
		return "album", fmt.Sprintf("album: %d photos, %d videos",
			x.GetExpectedImageCount(), x.GetExpectedVideoCount()), "", "", nil
	case m.GroupInviteMessage != nil:
		x := m.GetGroupInviteMessage()
		return "invite", strings.TrimSpace(x.GetGroupName() + "\n" + x.GetCaption()), "", "", nil
	case m.TemplateMessage != nil:
		return "template", templateText(m.GetTemplateMessage()), "", "", nil
	case m.InteractiveMessage != nil:
		x := m.GetInteractiveMessage()
		return "template", strings.TrimSpace(x.GetHeader().GetTitle() + "\n" + x.GetBody().GetText()), "", "", nil
	case m.ButtonsMessage != nil:
		return "template", m.GetButtonsMessage().GetContentText(), "", "", nil
	case m.ListMessage != nil:
		x := m.GetListMessage()
		return "template", strings.TrimSpace(x.GetTitle() + "\n" + x.GetDescription()), "", "", nil
	case m.ButtonsResponseMessage != nil:
		x := m.GetButtonsResponseMessage()
		return "reply", x.GetSelectedDisplayText(), x.GetContextInfo().GetStanzaID(), "", nil
	case m.TemplateButtonReplyMessage != nil:
		x := m.GetTemplateButtonReplyMessage()
		return "reply", x.GetSelectedDisplayText(), x.GetContextInfo().GetStanzaID(), "", nil
	case m.ListResponseMessage != nil:
		x := m.GetListResponseMessage()
		return "reply", x.GetTitle(), x.GetContextInfo().GetStanzaID(), "", nil
	case m.PlaceholderMessage != nil:
		// Content WhatsApp withholds from linked devices (kept on the phone).
		return "placeholder", m.GetPlaceholderMessage().GetType().String(), "", "", nil
	}
	// WhatsApp keeps adding FutureProofMessage envelopes (album children,
	// group mentions, event covers, ...). Describe whatever they wrap.
	var inner *waE2E.Message
	m.ProtoReflect().Range(func(fd protoreflect.FieldDescriptor, v protoreflect.Value) bool {
		if fd.Message() != nil && fd.Message().FullName() == "WAWebProtobufsE2E.FutureProofMessage" {
			if fp, ok := v.Message().Interface().(*waE2E.FutureProofMessage); ok && fp.GetMessage() != nil {
				inner = fp.GetMessage()
				return false
			}
		}
		return true
	})
	if inner != nil {
		return describe(inner)
	}
	return "", "", "", "", nil
}

func templateText(t *waE2E.TemplateMessage) string {
	h := t.GetHydratedTemplate()
	if h == nil {
		h = t.GetHydratedFourRowTemplate()
	}
	if h != nil {
		return strings.TrimSpace(strings.Join([]string{
			h.GetHydratedTitleText(), h.GetHydratedContentText(), h.GetHydratedFooterText(),
		}, "\n"))
	}
	if im := t.GetInteractiveMessageTemplate(); im != nil {
		return strings.TrimSpace(im.GetHeader().GetTitle() + "\n" + im.GetBody().GetText())
	}
	return ""
}

// pollOf returns the poll in any of WhatsApp's poll message versions.
func pollOf(m *waE2E.Message) *waE2E.PollCreationMessage {
	for _, p := range []*waE2E.PollCreationMessage{
		m.GetPollCreationMessage(), m.GetPollCreationMessageV2(), m.GetPollCreationMessageV3(),
		m.GetPollCreationMessageV5(), m.GetPollCreationMessageV6(),
	} {
		if p != nil {
			return p
		}
	}
	if inner := m.GetPollCreationMessageV4().GetMessage(); inner != nil {
		return pollOf(inner)
	}
	return nil
}

func pollOptions(p *waE2E.PollCreationMessage) []string {
	var names []string
	for _, o := range p.GetOptions() {
		names = append(names, o.GetOptionName())
	}
	return names
}

// Message fields that carry no user content (key exchange, wrappers, state).
var nonContentFields = map[string]bool{
	"messageContextInfo":                         true,
	"senderKeyDistributionMessage":               true,
	"fastRatchetKeySenderKeyDistributionMessage": true,
	"protocolMessage":                            true,
	"pollUpdateMessage":                          true,
	"keepInChatMessage":                          true,
	"pinInChatMessage":                           true,
	"encReactionMessage":                         true,
	"encCommentMessage":                          true,
	"encEventResponseMessage":                    true,
	"secretEncryptedMessage":                     true,
	"callLogMesssage":                            true,
	"messageHistoryNotice":                       true,
}

// unsupportedKind names the content field(s) of a message describe() does not
// understand, so such messages are kept (and counted) instead of vanishing.
func unsupportedKind(m *waE2E.Message) string {
	var names []string
	m.ProtoReflect().Range(func(fd protoreflect.FieldDescriptor, _ protoreflect.Value) bool {
		if name := string(fd.JSONName()); !nonContentFields[name] {
			names = append(names, name)
		}
		return true
	})
	if len(names) == 0 {
		return ""
	}
	return "unsupported:" + strings.Join(names, "+")
}
