# MessageBox (client-mod edition)

A modern, messenger-style replacement for the WoW 1.12 whisper system, based on
[tilare/MessageBox](https://github.com/tilare/MessageBox) (v2.5), extended to take advantage of the
common 1.12 client mods **when they are installed**, and hardened so it no longer crashes on
incomplete installs.

Everything new is optional and additive: with **no client mods installed it behaves like the
original**, and a failure inside any integration can never lose a whisper (see
[Safety design](#safety-design)).

> **Status:** developed and verified against a purpose-built WoW 1.12 / Lua 5.0 simulator
> (see [TESTING.md](TESTING.md)), **not yet played on a live client.** Please report anything the
> simulator could not catch. `/mbox trace on` + `/mbox trace dump` produces the diagnostics needed.

---

## Installation

1. Copy this folder to `Interface\AddOns\MessageBox\`.
2. **Make sure the binary asset folders from the upstream repo are present too:**
   `img\`, `font\` and `sound\`. They are not text, so they are not part of this tree.
   Copying only the `.lua` files is the cause of the `UI.lua:786` / `Font not set` crashes
   this edition fixes (see [Fixed](#fixed)). If they are missing the addon now still works
   (default font, stock bell icon) and prints a one-time hint at login.
3. Install any of the optional client mods below, then `/reload`. At login you will see e.g.
   `MessageBox: enhanced with ClassicAPI, Nampower, UnitXP_SP3.`

`MessageBox.toc` loads `Compat.lua` **last**; keep that order.

---

## Client mods used

| Mod | Used for | API it relies on | Required? |
|---|---|---|---|
| **ClassicAPI** | Identify a whisperer's class/race **the instant the whisper arrives** (no `/who` wait); persistent name→class cache that survives `/reload`/restart; silent `/who` that doesn't spam chat or pop the friends panel | `GetCurrentChatGUID()`, `GetPlayerInfoByGUID()`, `C_PlayerCache.SetEnabled/SetScanEnabled/RememberPlayer/GetPlayerInfoByName`, `C_FriendList.SendWhoQueryByName/IsWhoQueryPending`, `UnitGUID` | No |
| **UnitXP SP3** | Flash the Windows taskbar icon (and optionally play an OS sound) on incoming whispers while the game is in the background | `UnitXP("notify","taskbarIcon"/"systemSound")`; detected with `pcall(UnitXP,"nop","nop")` | No |
| **Nampower** | Crash-save backup (as upstream); optional world chat bubbles for whispers; GUID helper | `WriteCustomFile/ReadCustomFile/CustomFileExists` (upstream), CVar `NP_ChatBubblesWhisper`, `GetUnitGUID` | No (crash-save needs it) |
| **SuperWoW** | Detection and GUID lookup for a visible unit when ClassicAPI/Nampower don't provide `UnitGUID`/`GetUnitGUID` | `UnitExists(unit)` 2nd return (GUID), `SUPERWOW_VERSION` | No |
| **WeirdUtils** | `/mbox log` shows the path of today's raw chat log | `GetWeirdUtilsVersion("logsessions")`, `GetChatLogPath()` | No |

**Deliberately not used: VanillaHelpers.** Its feature set (minimap blips, model/texture/morph
helpers) has no meaningful surface in a whisper messenger; wiring it in would be decoration, not
function. SuperWoW's role is intentionally small for the same reason, and no SuperWoW behaviour
beyond what its README/ClassicAPI/Nampower docs guarantee is assumed.

Notes: the UnitXP SP3 and WeirdUtils repositories are archived upstream; they keep working but are
no longer receiving changes. `Interface: 11200` (1.12.x) only.

---

## Features

### Inherited from upstream
- **Whisper history**: stores and displays past whisper conversations
- **Popup notifications** with a minimap badge showing the unread count
- **Contact list** with search bar, unread counts, friends integration
- **Send whispers directly** from the window, with optional cascading **pop-out windows** (WIM-style)
- **Intercept whispers** typed in chat/UI and open the conversation instead
- **Chat search**, **Modern/Classic themes**, **colour picker**, **item & web link support**
- **Pin system**, **conversation management** (delete one / clear all)
- **Right-click context menu**: invite, target, add friend, ignore, delete, pin, pop out
- **Background /who queue** to fill in class/level/guild/zone for non-friends
- **Nampower crash-save** backup of conversations
- Commands: `/messagebox`, `/mbox`, `/mb`

### Fixed
| Problem | Cause | Fix |
|---|---|---|
| `UI.lua:786: attempt to index a nil value` when opening the window | `bellButton:GetNormalTexture()` returns `nil` when `img\bell-*.tga` is missing, and the code dereferenced it unconditionally | Nil-safe; falls back to a stock Blizzard bell icon (dimmed when notifications are off) |
| `UI.lua:1117: SetText(): Font not set` (and an error cascade after it) | `font\OpenSans.ttf` failed to load, leaving contact-row FontStrings without a font | Font is probed once at load and falls back to `Fonts\FRIZQT__.TTF` |
| Class colours wrong on non-English clients | `classUpper = string.upper(<localized class name>)` never matches `RAID_CLASS_COLORS` | Localized→engine-token map learned from `UnitClass`/`GetPlayerInfoByGUID`; persisted tokens re-normalised at login |
| Contacts never resolve on realms with a slow `/who` reply | Fixed 10 s timeout discards correct-but-slow answers | Late replies are detected, harvested, and the timeout is raised |

### New / improved
- **Instant class & race** for whisperers (ClassicAPI chat GUID → player info), or for free from
  your target/mouseover/party/raid with plain vanilla API. `/who` still fills guild/zone.
- **Persistent class cache** (`C_PlayerCache`) so colours survive restarts, even for offline players.
- **Adaptive `/who` throttle**: learns each realm's limit (details below) instead of a hardcoded 30 s / 10 s.
- **Silent `/who` via ClassicAPI**: no chat spam, friends panel not popped by background queries,
  doesn't collide with another addon's in-flight query.
- **Taskbar flash** on incoming whispers while the game is in the background (UnitXP).
- **Whisper chat bubbles** (Nampower), opt-in and non-destructive.
- **Raw chat log path** (WeirdUtils): `/mbox log`.
- **Runtime tracer**: `/mbox trace`.
- **Safety by construction**: every integration is `pcall`-guarded, SavedVariables-compatible, Lua 5.0 only.

---

## Commands

Stock: `/mbox` (toggle), `/mbox queue`, `/mbox clear`, `/mbox stress <contacts> <messages>`

Added:

| Command | Effect |
|---|---|
| `/mbox mods` | Which client mods were detected |
| `/mbox who` | Current interval/timeout, mode, counters (`sent ok dropped stale late`), queue depth |
| `/mbox who <seconds>` | Pin the interval (turns adaptive off) |
| `/mbox who auto` / `reset` | Re-enable adaptive / restore stock 30 s / 10 s |
| `/mbox who skip` | Toggle: don't `/who` contacts whose class is already known (guild/zone stay empty) |
| `/mbox who silent` | Toggle ClassicAPI silent `/who` |
| `/mbox xp [flash\|sound]` | Toggle UnitXP taskbar flash / OS sound (only effective while in background) |
| `/mbox bubbles [on\|off]` | Toggle Nampower whisper chat bubbles (restores the CVar only if we set it) |
| `/mbox log` | Path of today's chat log (WeirdUtils `logsessions`) |
| `/mbox trace on\|off\|dump\|clear\|echo` | Runtime trace of resolution/throttle decisions (200-line ring buffer) |

Settings added by this edition live in `MessageBoxSettings.compat` (per character); upstream keys are untouched.

---

## The adaptive `/who` throttle

Realms rate-limit `/who` differently and there is no API to ask. Upstream hardcodes a 30 s interval
and a 10 s timeout, which is too aggressive for strict realms (queries silently dropped, retries
burned, contact never resolves), too slow for quiet ones, and its fixed timeout throws away slow
but correct replies.

An AIMD controller steers `MessageBox.WHO_INTERVAL` / `WHO_TIMEOUT` (which the stock scheduler
re-reads every tick, so no stock logic is rewritten):

| Signal | Meaning | Response |
|---|---|---|
| timeout | server dropped the query | interval ×1.5 (×2 after 3 in a row); remember the failing interval as a floor for 30 min |
| stale | identical non-empty result, target absent | same as timeout |
| **late** | the "timed-out" query was actually answered later | **undo** the penalty, raise the timeout to 1.5× latency, harvest the data |
| success | 2 clean replies in a row | interval ×0.85, never below the floor or the 10 s minimum |

Bounds: 10–150 s interval (ClassicAPI documents that the server drops `CMSG_WHO` at ~5 s
granularity; 10 s keeps a margin, pin lower manually if you know your realm), timeout up to 45 s.
The learned values are saved per character, so each realm keeps its own.

**Measured in simulation** (40 contacts whisper at once, 2400 s; "resolved" = class + guild):

| Realm behaviour | Stock | Adaptive |
|---|---|---|
| No throttle | all 40 in 1172 s | all 40 in **510 s** |
| Throttle 12 s | 1172 s | 647 s |
| Throttle 25 s | 1172 s | 1164 s (≈ no gain; 2 probe drops) |
| Throttle 40 s | **34/40, 34 dropped queries** | **40/40, 2 dropped** |
| Replies after 14 s | **0/40** | **40/40** |

So the gain is at the extremes. On a realm whose limit is just under 30 s, stock is already fine.
With ClassicAPI, class colours for all 40 are available at **1 s** instead of after the `/who`
backlog drains. These numbers come from a simulated server (see [TESTING.md](TESTING.md)); real
realms may behave differently, which is why `/mbox who` exposes the counters.

---

## Safety design

- **Never breaks core.** Compat code that runs inside a core event or function is `pcall`-guarded;
  an error is recorded in the trace and the original behaviour continues (tested by injecting a
  throwing client-mod API during a whisper).
- **Same data, same schema.** Resolution writes only the cache fields the stock `/who` handler
  writes (`playerCache`, `settings.classCache`); `MessageBoxDB` and the message format are untouched.
- **GUID ownership check.** A chat GUID is only trusted if `GetPlayerInfoByGUID` returns the
  contact's own name; known GMs are never resolved or queried.
- **No hidden global changes.** Nampower's `NP_ChatBubblesWhisper` is never touched unless you opt in,
  and only reverted if this addon set it. `SendWho` is swapped only for the duration of one call and
  always restored.
- **Lua 5.0 clean.** Source is linted for 5.1+ constructs (`#`, `...`, `string.match`, `select`, …).

## Known limitations

- Not yet exercised on a live 1.12 client; the simulator mirrors documented semantics.
- `GetCurrentChatGUID()` is documented for incoming chat events; for `CHAT_MSG_WHISPER_INFORM` the
  name check above guards against a wrong GUID, falling back to the persistent name cache.
- The localized→token class map is learned lazily on non-English clients (your own class at login,
  then every class seen through `UnitClass`/ClassicAPI), so colours improve over time rather than
  being fully correct from the first whisper.
- With `/mbox who skip` on, guild/zone are intentionally not looked up.
- The friends-panel suppression follows ClassicAPI's documented pattern and only applies within 5 s of
  a query this addon sent; a user `/who` in that window won't pop the panel.

## Running the tests

```
cd tests
lua run_all.lua        # Lua 5.2+ on the host; the simulated WoW is restricted to Lua 5.0
lua t_throttle.lua     # throttle comparison table (informational)
lua t_trace.lua        # sample runtime traces (informational)
```

## Credits & license

Original addon: **tilr / tilare**, [github.com/tilare/MessageBox](https://github.com/tilare/MessageBox).
Check the upstream repository for its license terms before redistributing. `Compat.lua`, the
Core/UI patches and `tests/` are additions on top of that base; add the license of your choice.
Client mods are the work of their respective authors (ClassicAPI, UnitXP SP3 by konaka, Nampower by
namreeb/avitasia/brues-code, SuperWoW by balake, WeirdUtils by MarcelineVQ).
