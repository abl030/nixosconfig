// whatsapp-archive — receive-only WhatsApp archiver for the homelab.
//
// Links to the account as a companion device (like WhatsApp Web) via
// whatsmeow and writes every message to an append-only SQLite archive plus
// media files. It never sends messages, read receipts or presence.
//
//	whatsapp-archive run                       the daemon (systemd)
//	whatsapp-archive link [-phone +614...]     pair interactively (QR or code)
//	whatsapp-archive import-json -json result.json -base DIR
//	                                           merge a wtsexporter-decrypted
//	                                           Android backup (full history)
//
// Runbook: docs/wiki/services/whatsapp-archive.md
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"time"
)

func main() {
	log.SetFlags(0)
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: whatsapp-archive run|link|import-json [flags]")
		os.Exit(2)
	}
	cmd, args := os.Args[1], os.Args[2:]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	var cfg Config
	fs.StringVar(&cfg.DataDir, "data-dir", "/var/lib/whatsapp-archive", "session + archive.db directory (local disk, not NFS)")
	fs.StringVar(&cfg.MediaDir, "media-dir", "/var/lib/whatsapp-archive/media", "where media files are written")
	fs.StringVar(&cfg.HealthAddr, "health-addr", "127.0.0.1:9884", "health endpoint listen address")
	fs.IntVar(&cfg.HistoryMediaDays, "history-media-days", 30, "download media from history sync only when newer than this")
	phone := fs.String("phone", "", "link: phone number for a pairing code instead of a QR code")
	linger := fs.Duration("linger", 2*time.Minute, "link: keep receiving the initial history sync this long")
	jsonPath := fs.String("json", "", "import-json: wtsexporter result.json")
	baseDir := fs.String("base", ".", "import-json: directory wtsexporter ran in (media paths are relative to it)")
	_ = fs.Parse(args)

	var err error
	switch cmd {
	case "run":
		err = runDaemon(cfg)
	case "link":
		err = runLink(cfg, *phone, *linger)
	case "import-json":
		if *jsonPath == "" {
			log.Fatal("import-json: -json is required")
		}
		err = runImportJSON(cfg, *jsonPath, *baseDir)
	default:
		err = fmt.Errorf("unknown command %q", cmd)
	}
	if err != nil {
		log.Fatal(err)
	}
}
