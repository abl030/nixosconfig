package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/mdp/qrterminal/v3"
	"go.mau.fi/whatsmeow"
)

// runLink pairs a new companion device, interactively. With phone set it
// prints an 8-character pairing code (Linked devices -> Link with phone
// number); otherwise it renders QR codes in the terminal. The archive handler
// is attached throughout, so the history the phone pushes right after pairing
// is written (and only then acked).
func runLink(cfg Config, phone string, linger time.Duration) error {
	ctx := context.Background()
	_, device, err := openDevice(ctx, cfg.DataDir)
	if err != nil {
		return err
	}
	if device.ID != nil {
		fmt.Printf("already linked as %s; unlink it on the phone first, then remove %s to re-link\n",
			device.ID, sessionDB(cfg.DataDir))
		return nil
	}
	a, err := newArchiver(cfg, device)
	if err != nil {
		return err
	}
	qr, err := a.cli.GetQRChannel(ctx)
	if err != nil {
		return err
	}
	if err := a.cli.Connect(); err != nil {
		return err
	}
	defer a.cli.Disconnect()

	codeShown := false
	for item := range qr {
		switch item.Event {
		case whatsmeow.QRChannelEventCode:
			if phone == "" {
				fmt.Println("\nScan with WhatsApp -> Settings -> Linked devices -> Link a device:")
				qrterminal.GenerateHalfBlock(item.Code, qrterminal.L, os.Stdout)
			} else if !codeShown {
				code, err := a.cli.PairPhone(ctx, phone, true, whatsmeow.PairClientChrome, "Chrome (Linux)")
				if err != nil {
					return fmt.Errorf("pairing code: %w", err)
				}
				fmt.Printf("\nOn the phone: Linked devices -> Link a device -> Link with phone number instead\nEnter code: %s\n", code)
				codeShown = true
			}
		case whatsmeow.QRChannelEventError:
			return fmt.Errorf("pairing failed: %w", item.Error)
		case whatsmeow.QRChannelSuccess.Event:
			fmt.Printf("linked. Receiving the initial history sync for %v before handing over to the service...\n", linger)
			// Anything not received by then stays queued server-side (unacked)
			// and reaches the service as offline messages.
			time.Sleep(linger)
			return nil
		default:
			return fmt.Errorf("pairing ended: %s", item.Event)
		}
	}
	return fmt.Errorf("pairing channel closed without success")
}
