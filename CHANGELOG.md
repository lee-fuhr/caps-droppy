# Changelog

## [1.1.0] - 2026-10-02

- Works for anyone, with any number of Claude and Codex accounts in any mix. Lee, live 2026-10-02 10:31am: the public version supports any number and combination of Claude and Codex accounts, and Claude's exact usage comes from an opt-in step in setup that reads the user's own Claude Code login already saved on their Mac.
- Codex: reads every Codex folder it finds (and any folder you add), showing both the 5-hour and 7-day windows, named by folder.
- Claude: off until you turn it on. Caps reads the Claude Code login saved on your Mac and sends one usage request to Anthropic per refresh (never more than once a minute). It never stores, logs or forwards the login. A login that cannot report usage shows as such. No claude.ai web sign-in.
- Settings list what Caps found as real rows: each account has its service's mark, a switch and an optional name (needed only to tell two accounts of one service apart). A folder picker adds Codex folders. The Claude switch has one sentence beside it and the full disclosure one step away.
- Rows on the shelf card show the service's mark instead of a name, with even row heights and one clear gap between the Claude and Codex groups; the header clears the rounded corners.
- New Advanced setting: a snapshot file. Empty by default. Set to a snapshot file, accounts, budget holds, their banners and the backlog cap tick work as in 1.0.6; with no snapshot, the hold and cap UI is hidden.
- "Fleet" is now "total" in everything you read. Every 1.0.6 setting and alert rule is unchanged.

## [1.0.6] - 2026-10-02

- A settings page. Lee, live 2026-10-02 10:03am: 'I want to be able to easily toggle notifications on/off at least.'
- Notifications: one master switch (off means no notch banners at all), then one switch per banner:
  an account runs out, an account comes back, a budget hold lifts, a 5-hour window runs high.
- The 5-hour banner's level (default 90%) and the level a window must fall below to re-arm it (default 80%).
- Refresh rate (default 1 minute), show or hide the Codex row, show or hide the fleet gauge beside the notch.
- Every default is what 1.0.5 did. Switching a banner back on never replays changes that happened while it was off.

## [1.0.5] - 2026-09-30

- Condensed card: two lines per account. The 5-hour use sits small beside the big 7-day number.
- The backlog cap is a tick on the bar: bright and tall when backlog work may use the account,
  dim and short when it is held for client work. A key at the bottom shows both.
- Hover an account to see its cap and reset times in the bottom line. Nothing on the row moves.
- A spent account keeps its row: full dim bar, 100%, and when it comes back.

## [1.0.4] - 2026-09-30

- A short banner drops from the notch when an account runs out or comes back, when a budget hold
  lifts, or when a 5-hour window passes 90%. Each fires once per change and never repeats while
  the condition holds; starting Droppy fires nothing.

## [1.0.3] - 2026-09-30

- New card: one bar per account on one scale, with the budget cap drawn as a notch on the bar and
  repeated at the start of its line, so you can see how close each account is to its cap.
- Codex's weekly use now shows too, with how old the reading is.
- Spent accounts keep their place and say when they are back, instead of disappearing.
- Hover the card to switch every number to its reset time.
- The card grows and shrinks with the number of accounts, so there is no empty space.

## [1.0.0] - 2026-09-28

- First release.
