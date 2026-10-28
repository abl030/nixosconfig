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
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
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
		log.Printf("connected")
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

	kind, text, quoted, mimeType, dl := describe(evt.Message)
	if kind == "" {
		return // receipts, key distribution, app-state and other non-content messages
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
	if added && dl != nil {
		if source == "history" && time.Since(info.Timestamp) > time.Duration(a.cfg.HistoryMediaDays)*24*time.Hour {
			// Old history media is long gone from the CDN; the backup import has it.
			_ = a.arc.SetMedia(ctx, info.ID, "", "skipped")
			return
		}
		select {
		case a.media <- mediaJob{msgID: info.ID, ts: info.Timestamp, mime: mimeType, dl: dl}:
		default:
			_ = a.arc.SetMedia(ctx, info.ID, "", "queue-full")
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
	case m.PollCreationMessage != nil || m.PollCreationMessageV3 != nil:
		x := m.GetPollCreationMessage()
		if x == nil {
			x = m.GetPollCreationMessageV3()
		}
		opts := []string{x.GetName()}
		for _, o := range x.GetOptions() {
			opts = append(opts, "- "+o.GetOptionName())
		}
		return "poll", strings.Join(opts, "\n"), "", "", nil
	}
	return "", "", "", "", nil
}
