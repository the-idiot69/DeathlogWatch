# DeathlogWatch

A passive monitor for the [Deathlog](https://github.com/Deathwing/Deathlog) death-alert channel, for
server operators tracking down forged death reports.

Deathlog broadcasts every death as a plain chat message on a hidden,
password-protected realm-wide channel. The message carries the dead player's
name **as a field in the payload** — the actual sender of the chat line is a
separate thing entirely, and the receiving addon never checks that the two
agree. It also commits a death to its database on a **single** message, with no
requirement that any other client corroborate it.

The result: anyone who can join that channel can announce anyone's death, and
once it lands in the database there is nothing left to say who sent it. The
sender's name *is* available at the moment the message arrives, but
`handleDeathBroadcast` uses it only to pick a "quality" tier and then drops it
before writing the entry.

DeathlogWatch joins the same channel read-only and keeps the part Deathlog
throws away: **who broadcast each report**.

## What it does

For every death report on the channel, it records:

- the sender of the chat line
- the player whose death is being claimed
- level, guild, and damage source from the payload
- whether the sender and the claimed victim are the same character
- how many *other* clients independently corroborated the report

It transmits nothing. It joins the channel, listens, and writes to its own
SavedVariables file. It does not modify Deathlog, and it works fine alongside
it — or on its own, on an account with no Deathlog installed.

## Installing

Copy the whole `DeathlogWatch` folder into your AddOns directory:

```
World of Warcraft/_classic_era_/Interface/AddOns/DeathlogWatch/
├── DeathlogWatch.toc
├── DeathlogWatch.lua
├── LICENSE
└── README.md
```

That's the entire packaging story — a WoW addon is just a folder under
`Interface/AddOns/`. There is nothing to build and no dependencies.

**The folder name must be exactly `DeathlogWatch`**, matching the `.toc`
filename. This is the one rule that trips people up: if the folder is named
anything else (`DeathlogWatch-main` from a GitHub zip download, say), WoW will
not load it and it won't appear in the addon list at all.

Then fully restart the client (or `/reload`), and confirm **DeathlogWatch** is
checked in the AddOns list on the character-select screen.

The addon joins the channel about 6 seconds after you log in, and hides it from
your chat windows so you don't see the raw traffic.

## Using it

| Command | What it shows |
| --- | --- |
| `/dlwatch` | Command list, plus how much has been captured so far |
| `/dlwatch report` | Ranked summary of the most suspicious senders |
| `/dlwatch sender <name>` | Every report that character broadcast |
| `/dlwatch victim <name>` | Every report claiming that character died, and who sent each |
| `/dlwatch recent` | The last 20 reports seen, newest on the bottom line |
| `/dlwatch recent 50` | Same, with a custom count (max 100) |
| `/dlwatch export` | The full report in a copy-pasteable window |
| `/dlwatch clear` | Wipe everything collected so far |

`report` and `recent` both take an optional count.

Everything is written for a small chat window. Listings cap at 20 lines, and
they put the line that matters on the **bottom**, nearest the chat input —
chat scrolls downward, so the reverse would push it furthest away. For
`recent` that means newest last; for `report` it means the worst offender
last. Use `/dlwatch export` when you want everything at once in a scrollable
window.

`/dlwatch report` looks like this:

```
SENDER         SCORE UNCOR SRC-1  VICS
Beeflog           12     4     2     5
Ganksalot         47    19    11    19
worst listed last | 1284 events since 08/12 21:04:11
```

- **UNCOR** — peer reports (claiming *someone else* died) that no other client
  corroborated
- **COR** — peer reports that other clients did corroborate (export only)
- **SRC-1** — of the uncorroborated ones, how many were flagged `source_id=-1`,
  the "reported death" type that Deathlog auto-commits without waiting for any
  corroboration at all. The cheapest forgery, so it's weighted heaviest.
- **VICS** — distinct players this sender has claimed deaths for

## Reading the results

The signal to look for is the **ratio**, not any single line.

A normal client mostly broadcasts its own character's death, plus the
occasional party member's — and those get corroborated by other people who were
standing there and saw it. A forger produces a stream of peer reports for
players nobody else saw die, and never has a self-report of their own.

So: **an uncorroborated report is suspicious, not proof.** A real death with no
other addon user nearby also looks uncorroborated. What holds up is a sender
with many uncorroborated reports across many distinct victims, especially with
a high SRC-1 count. Use `/dlwatch sender <name>` to read the actual history
before acting on anyone.

## Coverage limits

Custom channels in Classic Era are realm-wide, so a single observer sees the
whole realm's traffic.

**A name in Deathlog but not in DeathlogWatch is normal.** This is the most
common surprise, and it is not a bug. DeathlogWatch only ever sees *live*
broadcasts on the channel. Deathlog's own database is additionally backfilled
by background sync, which pulls historical death records from other players —
so its UI contains deaths that were never broadcast while you were watching,
including deaths from before you installed anything. Only deaths that happened
during a watch session can appear here. `/dlwatch victim <name>` tells you the
size and start of the collected window when it comes up empty, so you can judge
whether a miss is meaningful.

One other partition to know about: Deathlog falls back to
`hcdeathalertschannelb` and then `...bb` when the main channel is full, and
clients on different overflow channels don't see each other. DeathlogWatch
joins all three. If the realm ever grows enough to need a fourth, add the
suffix to `joinChannels()`.

Data is capped at 6000 events and rolls over oldest-first, so a long-running
observer keeps a recent window rather than all history. Export periodically if
you need a durable record.

## Accented names

Names like `Zejá` and `Björn` are handled. Lookups are case-insensitive and
accent-folded, so all of these find the same character:

```
/dlwatch victim Zejá
/dlwatch victim zejá
/dlwatch victim Zeja
```

This matters more than it sounds. WoW's `string.lower()` is a byte-wise,
locale-dependent call with no understanding of UTF-8 — in a Latin-1 locale it
will rewrite the lead byte of a multibyte character and corrupt the name.
DeathlogWatch lowercases ASCII only and leaves multibyte sequences untouched.

If a lookup still misses, it prints near-matches from what it has recorded, so
you can tell a typo apart from a genuine absence.

Table columns are padded by character count rather than byte length, so an
accented name doesn't drag the row out of line. (`string.format("%-16s")` pads
by bytes, and `Zejá` is 5 bytes but 4 characters — enough to skew every column
after it.)

One caveat that isn't fixable from the addon: WoW ships no monospace font, so
in-game the columns are correctly padded but still render slightly ragged in
the proportional chat font. The text itself is square — paste `/dlwatch export`
into any editor or spreadsheet and it lines up properly.

## Building a release

```sh
./package.py
```

Writes `dist/DeathlogWatch-<version>.zip`, taking the version from the
`## Version:` line in the `.toc`. Needs only Python 3 — no `zip` binary, no
dependencies.

| Flag | Effect |
| --- | --- |
| `--list` | Show what would be packaged, build nothing |
| `--no-readme` | Omit this README from the archive |
| `--out DIR` | Write the zip somewhere other than `dist/` |

Git metadata, editor droppings, build artifacts, and the packaging script
itself are excluded. `LICENSE` is always included — the GPL requires it to
travel with the code, so `--no-readme` won't drop it. The README is kept by
default because it doubles as the usage guide for whoever installs the zip.

Two things the script checks, both of which produce an addon that fails
silently in-game rather than loudly:

- **The top-level folder in the zip is named after the `.toc`, not after your
  working directory.** A zip whose root is `DeathlogWatch-main/` installs to a
  folder WoW won't load. The script always writes `DeathlogWatch/`, and warns
  if your working directory disagrees.
- **Every file the `.toc` loads must actually be in the archive.** A `.toc`
  listing a missing file loads a half-broken addon with no error. The build
  refuses to produce that.

## Note on the underlying problem

This addon gives you attribution, not prevention. Any client can still forge
reports, and a determined abuser who learns they're being watched can spread
activity across characters.

Because every report is an ordinary chat message on a known channel, the
complete fix is server-side: log that channel centrally and attribute every
report to an account rather than a character. That can't be evaded from the
client, which this can.

## License

GPL-3.0, matching Deathlog, whose wire format this reimplements. See
[LICENSE](LICENSE).
