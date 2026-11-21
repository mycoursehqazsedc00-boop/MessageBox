# MessageBox (Patched for WoW 1.12 / Turtle WoW)

> A modern, messenger-style replacement for the WoW 1.12 whisper system, based on [tilare/MessageBox](https://github.com/tilare/MessageBox) (`v2.5`), hardened against missing assets and extended with optional client-mod integrations.

## Client Mods Used

| Mod | Purpose in this addon | API Used | Required? |
|---|---|---|---|
| **ClassicAPI** | Instant class, race, and sex resolution on incoming/outgoing whispers (including cross-faction); persistent name-to-class cache across reloads; silent `/who` queries without chat spam or friends-panel popups | `GetCurrentChatGUID`, `GetPlayerInfoByGUID`, `C_PlayerCache`, `C_FriendList.SendWhoQueryByName`, `C_FriendList.IsWhoQueryPending`, `UnitGUID` | Optional |
| **UnitXP SP3** | Flash the Windows taskbar icon and optionally play a cooldown-gated OS sound on incoming whispers while the client is in the background | `UnitXP("notify", "taskbarIcon" / "systemSound")`, `pcall(UnitXP, "nop", "nop")` | Optional |
| **Nampower** | Crash-save backup of conversations and settings; opt-in world chat bubbles for whispers; unit GUID lookup fallback | `WriteCustomFile`, `ReadCustomFile`, `CustomFileExists`, `NP_ChatBubblesWhisper`, `GetUnitGUID` | Optional (crash-save requires it) |
| **SuperWoW** | Mod detection and GUID lookup fallback for visible units when ClassicAPI/Nampower GUID helpers are absent | `SUPERWOW_VERSION`, `UnitExists(unit)` (2nd return) | Optional |
| **WeirdUtils** | Print the path to today's raw chat log via `/mbox log` | `GetWeirdUtilsVersion("logsessions")`, `GetChatLogPath` | Optional |

All client-mod integrations are optional and `pcall`-guarded: with no mods installed, the addon behaves like stock `MessageBox` and never drops a whisper if an optional API fails.

## Features

- **Whisper History & Contacts:** Stores per-character conversations (`MessageBoxDB`), unread counts, pinned contacts, contact search, and friend-list integration.
- **Messenger UI & Pop-outs:** Resizable main window, Modern and Classic themes, color picker, minimap badge, popup notifications, and cascading WIM-style detached pop-out windows.
- **Chat Tools:** Direct whisper sending, chat-edit whisper interception (`/w`, `/t`), conversation search with match highlighting, clickable item/spell/web links, and right-click context menu (invite, target, add friend, ignore, pin, pop out, delete).
- **Background `/who` Queue:** Automatically resolves unknown contacts' class, level, guild, and zone with GM filtering and Nampower crash-save recovery.

## What Was Added / Improved

- **Added:**
  - Instant contact class, race, and sex resolution via ClassicAPI (`GetCurrentChatGUID` / `GetPlayerInfoByGUID` / `C_PlayerCache`) and visible unit inspection (`target`, `mouseover`, `party1..4`, `raid1..40` with zero table/string allocation in `TryVisibleUnit`).
  - Cross-faction-friendly chat header info showing `Race (M)/(F)` when level/guild are unavailable.
  - Adaptive AIMD `/who` throttle controller (`MessageBox.WHO_INTERVAL` / `WHO_TIMEOUT`, 10–150s interval, up to 45s timeout) plus ClassicAPI silent `/who` and friends-panel popup suppression.
  - UnitXP SP3 background taskbar flash and cooldown-gated OS sound alert (`xpSoundCooldown`, default `2s`).
  - Opt-in Nampower whisper chat bubbles (`NP_ChatBubblesWhisper`, only reverted if set by this addon).
  - `/mbox stats` quick summary (conversation count, message count, cached players/classes/races/GMs, `/who` queue depth) and `/mbox trace` 200-line runtime diagnostic buffer.
- **Fixed:**
  - Nil-guarded `bellButton:GetNormalTexture()` (`UI.lua`) with stock icon fallback and probed `OpenSans.ttf` (`Core.lua`) with `Fonts\FRIZQT__.TTF` fallback when `img/` or `font/` assets are missing.
  - Prevented `UpdateContactList` and `UpdateChatHeader` from overwriting normalized `classUpper` tokens on non-English clients or wiping cached classes for offline friends.
  - Preserved `arg2` fallback in `OnHyperlinkClick` so Shift-Clicking non-item links (spells, enchants, quests) inserts them into the whisper input.
  - Harvested late `/who` replies instead of discarding them, undoing timeout penalties and refreshing both `_fmtCache` and open detached window headers.
  - Trimmed leading/trailing whitespace in `/mbox` slash command parsing.

## Usage

- **Stock commands:** `/messagebox`, `/mb`, `/mbox` (toggle window), `/mbox queue`, `/mbox clear`, `/mbox stress <contacts> <messages>`
- **Added commands:**
  - `/mbox mods` — list detected client mods
  - `/mbox stats` — show conversation, message, cache, and `/who` queue statistics
  - `/mbox who [status | <seconds> | auto | reset | skip | silent]` — inspect or tune `/who` throttling
  - `/mbox xp [flash | sound | cd <seconds>]` — configure UnitXP SP3 background alerts and sound cooldown
  - `/mbox bubbles [on | off]` — toggle Nampower whisper chat bubbles
  - `/mbox log` — print today's WeirdUtils chat log path
  - `/mbox trace [on | off | echo | dump | clear]` — toggle or dump the runtime trace buffer
  - `/mbox help` — list added slash commands

> **Asset note:** Make sure the upstream `img/`, `font/`, and `sound/` folders are present alongside the `.lua` files for custom icons, fonts, and notification sounds; if missing, the addon falls back to stock Blizzard UI assets.

## Testing

Offline simulator tests live in `tests/` (see `TESTING.md`) and require a host Lua 5.2+ CLI (`cd tests && lua run_all.lua`). Live WoW 1.12 / Turtle WoW client testing is still required after updates.

## Credits & License

- **Original addon:** `tilr` / `tilare` — [github.com/tilare/MessageBox](https://github.com/tilare/MessageBox) (v2.5)
- **Compatibility layer, bug fixes & test suite:** `Compat.lua`, `Core.lua`/`UI.lua` patches, and `tests/`
- **License:** Same as upstream unless stated otherwise.
