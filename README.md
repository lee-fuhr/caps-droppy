# Caps

How much of your Claude and Codex limits you have used, on [Droppy](https://getdroppy.app)'s
shelf and beside the notch. Built with [DroppyKit](https://getdroppy.app/docs/droppykit).

## What it shows

- A shelf card with one row per account: 7-day use as the big number and a bar, 5-hour use
  beside it, and the reset times when you hover a row.
- A total (the average 7-day use) as a small ring and percentage beside the notch.
- A short banner from the notch when an account runs out or comes back, or a 5-hour window
  runs high. Each banner can be switched off, and so can all of them.
- Any number of Claude and Codex accounts, in any mix. Name each one, or switch it off.

## Where the numbers come from

**Codex** is read from Codex's own session logs on your Mac: `~/.codex`, any `~/.codex-*`
folder beside it, `CODEX_HOME`, and any folder you add in settings. Nothing is sent anywhere.

**Claude** is opt-in. Until you turn on "Show Claude usage" in Caps' settings, Caps does not
touch your keychain and does not use the network.

When you turn it on, Caps:

- **reads** the Claude Code login already saved in your Mac's keychain (macOS asks you to
  allow this; "Always Allow" stops it asking again),
- **sends** one usage request to Anthropic per refresh, from your Mac, never more than once a
  minute, and backs off if Anthropic says to slow down,
- **never** stores the login, writes it to a file, logs it, or sends it anywhere other than
  that one request to Anthropic. Caps never renews the login; Claude Code does that.

This is Claude Code's own login on your own Mac. It is not a claude.ai web sign-in, and Caps
has none. A login that Anthropic says cannot report usage shows as "can't report usage"; sign
in to Claude Code again to fix it.

## Privacy

Everything stays on your Mac except the one Claude request above. Caps has no account, no
analytics and no server of its own. It identifies itself to Anthropic as `Caps-Droppy/<version>`.

## Advanced: snapshot file

Settings, Advanced, "Snapshot file" is empty by default. If another tool of yours keeps a JSON
file with an `accounts` list (each entry `account`, `available`, `seven_day_pct`,
`five_hour_pct`, the reset times, and optionally `release_decision` with `ceiling_pct`,
`hours_to_reset`, `released`), point Caps at it and those accounts join the card. Accounts
with a `release_decision` also get a budget-hold tick on the bar and a "hold lifts" banner;
without one, none of that shows. The file is read, never written, and ignored when older than
five minutes.

## Developing

```bash
droppykit run        # open it in Droppy's Settings panel
droppykit build      # produce Capsdroppy.droplet
droppykit validate   # the checks the Store repository runs
swift test           # unit tests: alerts, Codex and Claude parsing, backoff, total
```

Preview switches for the harness (unset in Droppy): `CAPS_PREVIEW_SNAPSHOT`,
`CAPS_PREVIEW_HOME`, `CAPS_PREVIEW_KEYCHAIN` (lists names; never touches the keychain or the
network), `CAPS_PREVIEW_OPTIN`, `CAPS_PREVIEW_ONBOARDED`, `CAPS_PREVIEW_HOVER`.

MIT licence.
