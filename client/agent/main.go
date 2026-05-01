// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// ota-agent is the user-facing CLI of Ogamita Delta OTA.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"gitlab.com/ogamita/delta-ota/client/internal/transport"
	"gitlab.com/ogamita/delta-ota/client/libota"
)

const usage = `ota-agent — Ogamita Delta OTA client

Usage:
  ota-agent install   <name> [--version=X|--latest] [--server=URL]
  ota-agent upgrade   <name> [--to=X|--latest]      [--server=URL]
  ota-agent revert    <name>
  ota-agent list      [--remote|--local]
  ota-agent show      <name>
  ota-agent verify    <name>
  ota-agent prune     <name> [--archive-depth=N]
  ota-agent watch     <name> [--interval=24h]
  ota-agent doctor    [<name> --recover]
  ota-agent licenses
  ota-agent version

Environment:
  OTA_HOME      base directory for installs (default: ~/.ota)
  OTA_SERVER    default server URL when --server is not given
`

func main() {
	flag.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	flag.Parse()

	if flag.NArg() == 0 {
		flag.Usage()
		os.Exit(2)
	}

	switch flag.Arg(0) {
	case "version":
		fmt.Printf("ota-agent %s\n", libota.Version)
	case "licenses":
		printLicenses()
	case "install":
		installCmd(flag.Args()[1:])
	case "upgrade":
		upgradeCmd(flag.Args()[1:])
	case "revert":
		revertCmd(flag.Args()[1:])
	case "doctor":
		doctorCmd(flag.Args()[1:])
	case "watch":
		watchCmd(flag.Args()[1:])
	case "list", "show", "verify", "prune":
		fmt.Fprintf(os.Stderr, "ota-agent: %q not implemented yet\n", flag.Arg(0))
		os.Exit(1)
	default:
		flag.Usage()
		os.Exit(2)
	}
}

// reorderFlags moves all -- and -X-style flag tokens to the front so
// Go's flag package (which stops at the first positional) picks them
// up regardless of where the user wrote them.
func reorderFlags(args []string) []string {
	flags, pos := []string{}, []string{}
	for _, a := range args {
		if strings.HasPrefix(a, "-") {
			flags = append(flags, a)
		} else if len(flags) > 0 && strings.HasPrefix(flags[len(flags)-1], "-") &&
			!strings.Contains(flags[len(flags)-1], "=") {
			// Previous flag had no '=', so this is its value.
			flags = append(flags, a)
		} else {
			pos = append(pos, a)
		}
	}
	return append(flags, pos...)
}

type installArgs struct {
	name, version, server, installToken, hwinfo string
}

func parseInstallFlags(args []string) installArgs {
	args = reorderFlags(args)
	fs := flag.NewFlagSet("install", flag.ExitOnError)
	v := fs.String("version", "", "explicit version (defaults to latest)")
	latest := fs.Bool("latest", false, "explicitly request latest")
	srv := fs.String("server", os.Getenv("OTA_SERVER"), "server URL")
	tok := fs.String("install-token", os.Getenv("OTA_INSTALL_TOKEN"),
		"one-shot install token issued by the install page")
	hw := fs.String("hwinfo", "", "free-form workstation identifier (defaults to hostname)")
	_ = fs.Parse(args)
	if fs.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "install: missing <name>")
		os.Exit(2)
	}
	out := installArgs{
		name:         fs.Arg(0),
		version:      *v,
		server:       *srv,
		installToken: *tok,
		hwinfo:       *hw,
	}
	if *latest {
		out.version = "latest"
	}
	if out.server == "" {
		fmt.Fprintln(os.Stderr, "install: --server or $OTA_SERVER required")
		os.Exit(2)
	}
	if out.hwinfo == "" {
		if h, err := os.Hostname(); err == nil {
			out.hwinfo = h
		}
	}
	return out
}

func installCmd(args []string) {
	a := parseInstallFlags(args)
	cfg := libota.Config{
		ServerURL:      strings.TrimRight(a.server, "/"),
		OTAHome:        os.Getenv("OTA_HOME"),
		TrustedPubKeys: parsePubKeys(os.Getenv("OTA_TRUSTED_PUBKEYS")),
		Timeout:        2 * time.Minute,
		InstallToken:   a.installToken,
		Hwinfo:         a.hwinfo,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	v, err := libota.Install(ctx, cfg, a.name, a.version)
	if err != nil {
		fmt.Fprintf(os.Stderr, "install: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("installed %s %s\n", a.name, v)
}

func upgradeCmd(args []string) {
	args = reorderFlags(args)
	fs := flag.NewFlagSet("upgrade", flag.ExitOnError)
	to := fs.String("to", "latest", "target version")
	srv := fs.String("server", os.Getenv("OTA_SERVER"), "server URL")
	_ = fs.Parse(args)
	if fs.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "upgrade: missing <name>")
		os.Exit(2)
	}
	name := fs.Arg(0)
	server := *srv
	if server == "" {
		fmt.Fprintln(os.Stderr, "upgrade: --server or $OTA_SERVER required")
		os.Exit(2)
	}
	cfg := libota.Config{
		ServerURL:      strings.TrimRight(server, "/"),
		OTAHome:        os.Getenv("OTA_HOME"),
		TrustedPubKeys: parsePubKeys(os.Getenv("OTA_TRUSTED_PUBKEYS")),
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	v, err := libota.Upgrade(ctx, cfg, name, *to)
	if err != nil {
		fmt.Fprintf(os.Stderr, "upgrade: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("upgraded %s to %s\n", name, v)
}

// watchCmd runs `ota-agent upgrade <name> --to=latest` on a fixed
// interval, sleeping in between. Designed to be run as a long-lived
// foreground process under cron / systemd / launchd / Windows Task
// Scheduler.  --once exits after a single check.
func watchCmd(args []string) {
	args = reorderFlags(args)
	fs := flag.NewFlagSet("watch", flag.ExitOnError)
	srv := fs.String("server", os.Getenv("OTA_SERVER"), "server URL")
	interval := fs.Duration("interval", 24*time.Hour, "polling interval")
	once := fs.Bool("once", false, "check once and exit")
	_ = fs.Parse(args)
	if fs.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "watch: missing <name>")
		os.Exit(2)
	}
	name := fs.Arg(0)
	server := *srv
	if server == "" {
		fmt.Fprintln(os.Stderr, "watch: --server or $OTA_SERVER required")
		os.Exit(2)
	}
	cfg := libota.Config{
		ServerURL:      strings.TrimRight(server, "/"),
		OTAHome:        os.Getenv("OTA_HOME"),
		TrustedPubKeys: parsePubKeys(os.Getenv("OTA_TRUSTED_PUBKEYS")),
	}
	check := func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel()
		v, err := libota.Upgrade(ctx, cfg, name, "latest")
		if err != nil {
			fmt.Fprintf(os.Stderr, "[%s] watch: %v\n", time.Now().UTC().Format(time.RFC3339), err)
			return
		}
		fmt.Printf("[%s] %s @ %s\n", time.Now().UTC().Format(time.RFC3339), name, v)
	}
	check()
	if *once {
		return
	}
	tick := time.NewTicker(*interval)
	defer tick.Stop()
	for range tick.C {
		check()
	}
}

func doctorCmd(args []string) {
	args = reorderFlags(args)
	fs := flag.NewFlagSet("doctor", flag.ExitOnError)
	srv := fs.String("server", os.Getenv("OTA_SERVER"), "server URL")
	recover := fs.String("recover", "", "version to install (multi-step rollback)")
	_ = fs.Parse(args)
	if fs.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "doctor: missing <name>")
		os.Exit(2)
	}
	name := fs.Arg(0)
	server := *srv
	if server == "" {
		fmt.Fprintln(os.Stderr, "doctor: --server or $OTA_SERVER required")
		os.Exit(2)
	}

	ota_home := os.Getenv("OTA_HOME")
	if ota_home == "" {
		if h, err := os.UserHomeDir(); err == nil {
			ota_home = filepath.Join(h, ".ota")
		}
	}
	root := filepath.Join(ota_home, name)

	// 1. Local distributions on disk.
	fmt.Printf("=== %s — local installations under %s ===\n", name, root)
	if entries, err := os.ReadDir(root); err == nil {
		for _, e := range entries {
			n := e.Name()
			if strings.HasPrefix(n, "distribution-") {
				fmt.Printf("  %s\n", n)
			}
		}
	} else {
		fmt.Printf("  (no directory at %s)\n", root)
	}

	// 2. Server-curated anchors.
	fmt.Printf("\n=== %s — server-curated anchors ===\n", name)
	tr := transport.New(strings.TrimRight(server, "/"))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	anchors, err := tr.Anchors(ctx, name)
	if err != nil {
		fmt.Fprintf(os.Stderr, "doctor: anchors: %v\n", err)
		// Continue: maybe the user only wants local info.
	} else {
		for _, a := range anchors {
			fmt.Printf("  %-12s reason=%s\n", a.Version, a.Reason)
		}
		if len(anchors) == 0 {
			fmt.Println("  (none)")
		}
	}

	// 3. If --recover=<version> was passed, install that.
	if *recover != "" {
		fmt.Printf("\n=== recovering: installing %s %s ===\n", name, *recover)
		cfg := libota.Config{
			ServerURL:      strings.TrimRight(server, "/"),
			OTAHome:        ota_home,
			TrustedPubKeys: parsePubKeys(os.Getenv("OTA_TRUSTED_PUBKEYS")),
			Timeout:        2 * time.Minute,
		}
		ctx2, cancel2 := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel2()
		v, err := libota.Install(ctx2, cfg, name, *recover)
		if err != nil {
			fmt.Fprintf(os.Stderr, "doctor: recover: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("recovered %s -> %s\n", name, v)
	}
}

func revertCmd(args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "revert: missing <name>")
		os.Exit(2)
	}
	cfg := libota.Config{OTAHome: os.Getenv("OTA_HOME")}
	if err := libota.Revert(cfg, args[0]); err != nil {
		fmt.Fprintf(os.Stderr, "revert: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("reverted %s\n", args[0])
}

func parsePubKeys(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}

func printLicenses() {
	fmt.Println("Ogamita Delta OTA — AGPL-3.0-or-later")
	fmt.Println("Copyright (C) 2026 Ogamita Ltd.")
	fmt.Println("See docs/THIRD_PARTY_LICENSES.org for vendored components.")
}
