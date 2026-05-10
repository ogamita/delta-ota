// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2026 Ogamita Ltd.

// ota-agent is the user-facing CLI of Ogamita Delta OTA.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"gitlab.com/ogamita/delta-ota/client/internal/listing"
	"gitlab.com/ogamita/delta-ota/client/internal/transport"
	"gitlab.com/ogamita/delta-ota/client/internal/verify"
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
  ota-agent set-email   <name> <address>      register an email for upgrade notifications
  ota-agent unset-email <name> [<address>]    remove one address (or all)
  ota-agent show-email  <name>                list registered addresses
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
	case "list":
		listCmd(flag.Args()[1:])
	case "show":
		showCmd(flag.Args()[1:])
	case "verify":
		verifyCmd(flag.Args()[1:])
	case "prune":
		pruneCmd(flag.Args()[1:])
	case "set-email":
		setEmailCmd(flag.Args()[1:])
	case "unset-email":
		unsetEmailCmd(flag.Args()[1:])
	case "show-email":
		showEmailCmd(flag.Args()[1:])
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
			// v1.5: doctor --recover is a distinct transition kind in
			// the audit log and the snapshot table.
			Kind: "recover",
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

// ---------------------------------------------------------------------------
// v1.7 email subcommands
// ---------------------------------------------------------------------------

func emailClientFor(software string) (*libota.EmailClient, error) {
	ota_home := os.Getenv("OTA_HOME")
	if ota_home == "" {
		if h, err := os.UserHomeDir(); err == nil {
			ota_home = filepath.Join(h, ".ota")
		}
	}
	return libota.NewEmailClient(ota_home, software)
}

func setEmailCmd(args []string) {
	if len(args) < 2 {
		fmt.Fprintln(os.Stderr, "set-email: usage: ota-agent set-email <name> <address>")
		os.Exit(2)
	}
	c, err := emailClientFor(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "set-email: %v\n", err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := c.Set(ctx, args[1]); err != nil {
		fmt.Fprintf(os.Stderr, "set-email: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("registered %s for %s\n", args[1], args[0])
}

func unsetEmailCmd(args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "unset-email: usage: ota-agent unset-email <name> [<address>]")
		os.Exit(2)
	}
	c, err := emailClientFor(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "unset-email: %v\n", err)
		os.Exit(1)
	}
	addr := ""
	if len(args) >= 2 {
		addr = args[1]
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	deleted, err := c.Unset(ctx, addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "unset-email: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("removed %d address(es) for %s\n", deleted, args[0])
}

func showEmailCmd(args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "show-email: usage: ota-agent show-email <name>")
		os.Exit(2)
	}
	c, err := emailClientFor(args[0])
	if err != nil {
		fmt.Fprintf(os.Stderr, "show-email: %v\n", err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	rows, err := c.Show(ctx)
	if err != nil {
		fmt.Fprintf(os.Stderr, "show-email: %v\n", err)
		os.Exit(1)
	}
	if len(rows) == 0 {
		fmt.Printf("no emails registered for %s\n", args[0])
		return
	}
	fmt.Printf("registered emails for %s:\n", args[0])
	for _, r := range rows {
		verified := "unverified"
		if r.VerifiedAt != "" {
			verified = "verified"
		}
		fmt.Printf("  %-40s opted-in=%s (%s)\n", r.Email, r.OptedInAt, verified)
	}
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

// otaHomeOrDie returns $OTA_HOME, falling back to $HOME/.ota.
// Mirrors libota.defaultOTAHome but is reusable from the CLI without
// pulling libota in.
func otaHomeOrDie() string {
	if v := os.Getenv("OTA_HOME"); v != "" {
		return v
	}
	if h, err := os.UserHomeDir(); err == nil {
		return filepath.Join(h, ".ota")
	}
	return ".ota"
}

// humanBytes formats N bytes as a short power-of-1024 string.
func humanBytes(n int64) string {
	const (
		k = 1 << 10
		m = 1 << 20
		g = 1 << 30
	)
	switch {
	case n >= g:
		return fmt.Sprintf("%.1f GiB", float64(n)/float64(g))
	case n >= m:
		return fmt.Sprintf("%.1f MiB", float64(n)/float64(m))
	case n >= k:
		return fmt.Sprintf("%.1f KiB", float64(n)/float64(k))
	default:
		return fmt.Sprintf("%d B", n)
	}
}

// ---------------------------------------------------------------------------
// list [--remote|--local]
// ---------------------------------------------------------------------------

func listCmd(args []string) {
	args = reorderFlags(args)
	fs := flag.NewFlagSet("list", flag.ExitOnError)
	remote := fs.Bool("remote", false, "list software offered by the server")
	local := fs.Bool("local", false, "list software installed locally (default)")
	latest := fs.Bool("latest", false,
		"with --remote: show one row per software with its latest version (default: show every release)")
	srv := fs.String("server", os.Getenv("OTA_SERVER"), "server URL (with --remote)")
	_ = fs.Parse(args)

	// Default to --local when neither flag is given.
	if !*remote && !*local {
		*local = true
	}
	if *remote && *local {
		fmt.Fprintln(os.Stderr, "list: --remote and --local are mutually exclusive")
		os.Exit(2)
	}

	if *local {
		entries, err := listing.ListLocal(otaHomeOrDie())
		if err != nil {
			fmt.Fprintf(os.Stderr, "list: %v\n", err)
			os.Exit(1)
		}
		if len(entries) == 0 {
			fmt.Printf("(no software installed under %s)\n", otaHomeOrDie())
			return
		}
		fmt.Printf("%-24s %-12s %-12s %-10s %s\n",
			"SOFTWARE", "CURRENT", "PREVIOUS", "ON DISK", "SERVER")
		for _, e := range entries {
			fmt.Printf("%-24s %-12s %-12s %-10s %s\n",
				e.Software,
				orDash(e.Current),
				orDash(e.Previous),
				humanBytes(e.OnDiskBytes),
				orDash(e.ServerURL))
		}
		return
	}

	// --remote
	if *srv == "" {
		fmt.Fprintln(os.Stderr, "list: --remote requires --server or $OTA_SERVER")
		os.Exit(2)
	}
	tr := transport.New(strings.TrimRight(*srv, "/"))
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if *latest {
		// One row per software, with the most-recently-published version.
		rems, err := listing.ListRemoteSoftware(ctx, tr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "list --remote --latest: %v\n", err)
			os.Exit(1)
		}
		if len(rems) == 0 {
			fmt.Printf("(server %s has no software in its catalogue)\n", *srv)
			return
		}
		fmt.Printf("%-24s %-12s %-30s %s\n",
			"SOFTWARE", "LATEST", "DISPLAY NAME", "CREATED")
		for _, r := range rems {
			ver := r.LatestVersion
			if ver == "" {
				if r.LatestErr != nil {
					ver = "(no release)"
				} else {
					ver = "(none)"
				}
			}
			fmt.Printf("%-24s %-12s %-30s %s\n",
				r.Name, ver, r.DisplayName, r.CreatedAt)
		}
		return
	}

	// Default --remote view: every release of every software.
	rels, err := listing.ListRemoteReleases(ctx, tr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "list --remote: %v\n", err)
		os.Exit(1)
	}
	if len(rels) == 0 {
		fmt.Printf("(server %s has no releases in its catalogue)\n", *srv)
		return
	}
	fmt.Printf("%-24s %-12s %-12s %-10s %-12s %s\n",
		"SOFTWARE", "VERSION", "OS-ARCH", "BLOB", "FLAGS", "PUBLISHED")
	for _, r := range rels {
		flags := ""
		if r.Deprecated {
			flags += "deprecated "
		}
		if r.Uncollectable {
			flags += "uncollectable "
		}
		flags = strings.TrimSpace(flags)
		fmt.Printf("%-24s %-12s %-12s %-10s %-12s %s\n",
			r.Software,
			r.Version,
			r.OS+"-"+r.Arch,
			humanBytes(r.BlobSize),
			orDash(flags),
			r.PublishedAt)
	}
}

func orDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// ---------------------------------------------------------------------------
// show <name>
// ---------------------------------------------------------------------------

func showCmd(args []string) {
	if len(args) < 1 {
		fmt.Fprintln(os.Stderr, "show: missing <name>")
		os.Exit(2)
	}
	name := args[0]
	entry, err := listing.LoadLocal(otaHomeOrDie(), name)
	if errors.Is(err, fs.ErrNotExist) {
		fmt.Fprintf(os.Stderr, "show: %s is not installed under %s\n", name, otaHomeOrDie())
		os.Exit(1)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "show: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("software         : %s\n", entry.Software)
	fmt.Printf("current version  : %s\n", orDash(entry.Current))
	fmt.Printf("previous version : %s\n", orDash(entry.Previous))
	fmt.Printf("server URL       : %s\n", orDash(entry.ServerURL))
	if !entry.UpdatedAt.IsZero() {
		fmt.Printf("last updated     : %s\n", entry.UpdatedAt.UTC().Format(time.RFC3339))
	}
	fmt.Printf("history length   : %d revisions\n", entry.HistoryLength)
	fmt.Printf("on-disk size     : %s\n", humanBytes(entry.OnDiskBytes))
	fmt.Printf("distributions    : %d directories\n", len(entry.Distributions))
	for _, d := range entry.Distributions {
		marker := "  "
		switch {
		case d == "distribution-"+entry.Current:
			marker = "* " // active
		case d == "distribution-"+entry.Previous:
			marker = "p " // previous
		}
		fmt.Printf("  %s%s\n", marker, d)
	}
}

// ---------------------------------------------------------------------------
// verify <name> [--offline]
// ---------------------------------------------------------------------------

func verifyCmd(args []string) {
	args = reorderFlags(args)
	fs := flag.NewFlagSet("verify", flag.ExitOnError)
	offline := fs.Bool("offline", false, "skip the manifest fetch + signature check")
	srv := fs.String("server", os.Getenv("OTA_SERVER"), "server URL for online checks")
	_ = fs.Parse(args)
	if fs.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "verify: missing <name>")
		os.Exit(2)
	}
	name := fs.Arg(0)
	rep, err := verify.Verify(otaHomeOrDie(), name, verify.VerifyOptions{
		Offline: *offline,
		Server:  strings.TrimRight(*srv, "/"),
		Trusted: parsePubKeys(os.Getenv("OTA_TRUSTED_PUBKEYS")),
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "verify: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("=== ota-agent verify %s%s ===\n",
		rep.Software,
		func() string {
			if rep.Version != "" {
				return " @ " + rep.Version
			}
			return ""
		}())
	for _, c := range rep.Checks {
		mark := "✓"
		if !c.OK {
			mark = "✗"
		}
		fmt.Printf("  %s %-22s %s\n", mark, c.Name, c.Detail)
	}
	if rep.AllOK() {
		fmt.Println("OK")
		return
	}
	fmt.Fprintln(os.Stderr, "FAIL: one or more checks did not pass")
	os.Exit(1)
}

// ---------------------------------------------------------------------------
// prune <name> [--archive-depth=N] [--dry-run]
// ---------------------------------------------------------------------------

func pruneCmd(args []string) {
	args = reorderFlags(args)
	fs := flag.NewFlagSet("prune", flag.ExitOnError)
	depth := fs.Int("archive-depth", 2,
		"how many extra distribution-* dirs to keep beyond current+previous")
	dry := fs.Bool("dry-run", false, "list what would be deleted without removing it")
	_ = fs.Parse(args)
	if fs.NArg() < 1 {
		fmt.Fprintln(os.Stderr, "prune: missing <name>")
		os.Exit(2)
	}
	if *depth < 0 {
		fmt.Fprintln(os.Stderr, "prune: --archive-depth must be >= 0")
		os.Exit(2)
	}
	name := fs.Arg(0)
	cands, err := listing.PruneCandidates(otaHomeOrDie(), name, *depth)
	if err != nil {
		fmt.Fprintf(os.Stderr, "prune: %v\n", err)
		os.Exit(1)
	}
	if len(cands) == 0 {
		fmt.Printf("nothing to prune under %s/%s (depth=%d)\n",
			otaHomeOrDie(), name, *depth)
		return
	}
	for _, d := range cands {
		if *dry {
			fmt.Printf("would delete  %s\n", d)
			continue
		}
		if err := listing.DeleteDistribution(otaHomeOrDie(), name, d); err != nil {
			fmt.Fprintf(os.Stderr, "prune: %v\n", err)
			os.Exit(1)
		}
		fmt.Printf("deleted       %s\n", d)
	}
}
