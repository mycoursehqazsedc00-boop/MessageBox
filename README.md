# MessageBox
Adds optional integrations with ClassicAPI, SuperWoW, Nampower, UnitXP_SP3, and WeirdUtils to tilare's MessageBox. Every feature detects its dependency at runtime -- install none, some, or all of the above and MessageBox behaves the same as stock either way, just better where a given mod happens to be present.

**Nampower** is optional, but required for crash save backup

 ## Features

 **Whisper History –** Stores and displays your past whisper conversations.

 **Popup Notifications –** Get alerts when a new whisper arrives. The minimap button also has a red notification badge that displays the unread message count.

 **Contact List –** View all your contacts in one place, complete with a search bar and unread message counts.

 **Send Direct Whispers –** Message players straight from the addon's window, now with optional cascading popout windows, similar to WIM.

 **Intercept Whispers -** Let MessageBox intercept whisper commands in UI or chat, opening up to who you were trying to whisper. 

 **Chat Search -** Search through your chat logs with the search bar

 **Modern and Classic Themes -** Toggle the Classic theme for a more Blizzard-style UI.

 **Background Who Queue -** Toggle to enable a /who lookup on a 30 second cooldown that runs in the background to fill out information for your contacts that you do not have added as a friend.

 **Right Click Context Menu -** Right click on contacts to show options to Invite, Target, Add Friend, Ignore, Delete, Pin, and Pop Out Conversation.

 **Color Picker -** Customize your UI with a color picker. 

 **Linking Support -** Supports item linking and web links.

 **Pin System -** Pin a conversation to prevent it from being deleted, and keeps it at the top of your conversation list.

 **Conversation Management –** Delete individual chats or clear your entire history at once.

 **Commands -** Open the UI with /messagebox, /mbox, or /mb.
## What each integration does

- **ClassicAPI** -- resolves a whisperer's class/race the instant their
  message arrives, using `GetCurrentChatGUID()` + `GetPlayerInfoByGUID()`
  instead of waiting on MessageBox's 30-second `/who` throttle. Also opts
  MessageBox into ClassicAPI's on-disk name/class cache
  (`C_PlayerCache.SetEnabled` / `SetScanEnabled`), so contacts keep their
  class color across `/reload`s and even resolve while offline if you've
  whispered them before. `/who` is still sent afterward to pick up
  guild/zone, which ClassicAPI doesn't expose.

- **SuperWoW / Nampower** -- free, instant class/race resolution when the
  whisperer happens to already be your target, mouseover, or in your
  party/raid, by reading `UnitClass`/`UnitRace` off that unit directly
  (no network call at all). This path works even without either mod
  installed, but both extend the unit-token API to resolve by GUID rather
  than name string, which is what makes the match exact rather than
  name-string-fragile.

- **Nampower** -- turns on `NP_ChatBubblesWhisper` so whisperers still get
  a chat bubble over their head in the world, since MessageBox normally
  intercepts/hides the raw whisper line from the default chat frame.

- **UnitXP_SP3** -- MessageBox's existing popup notification also flashes
  the Windows taskbar icon and plays an OS-level sound
  (`UnitXP("notify", "taskbarIcon"/"systemSound")`), so a backgrounded
  client still gets your attention. (UnitXP's own notify calls already
  no-op while the game window is focused.)

- **WeirdUtils** -- if its `logsessions` module is loaded, adds
  `/mbox log` to print the path of today's plaintext chat log, for anyone
  who wants a raw backup alongside `MessageBoxDB`.

- Always available regardless of what's installed: `/mbox mods` prints
  which of the above were detected this session, and the adaptive `/who`
  throttle below works with no client mods at all.

## The /who throttle problem

Every server rate-limits `/who` differently, and there's no API to ask what
the limit is. MessageBox ships with `WHO_INTERVAL = 30` and
`WHO_TIMEOUT = 10` hardcoded, which is wrong in both directions:

- **Throttled realms** (Turtle and friends): queries get silently dropped.
  `WHO_LIST_UPDATE` never fires, the stock code times out after 10s,
  requeues, and burns the entry's 3 retries on nothing. That contact never
  resolves.
- **Quiet realms**: 30s is far slower than necessary. A 50-name backlog
  takes 25 minutes to drain.
- **Slow realms**: the fixed 10s timeout throws away *correct* answers that
  arrive at 12s, because `waitingForWhoResult` has already been cleared by
  the time `HandleWhoResult` runs.

So Compat.lua measures it instead. It's an AIMD controller (additive
decrease, multiplicative increase) driving `MessageBox.WHO_INTERVAL` and
`MessageBox.WHO_TIMEOUT`, both of which Logic.lua re-reads on every
scheduler tick -- so steering them is enough, no rewrite of the stock queue
logic required.

Four observable signals:

| Signal | What it means | Response |
|---|---|---|
| **Timeout** | `SendWho` fired, no `WHO_LIST_UPDATE` within the timeout | Server dropped it. Interval x1.5 (x2.0 after 3 in a row) |
| **Stale** | Results came back byte-identical to the previous query, target absent | Server ignored the query, we re-read the old set. Same back-off |
| **Late** | Reply arrived after we'd given up, with genuinely new contents | Server is slow, not throttling. Raise the *timeout*, leave the interval alone |
| **Success** | Fresh results in time | After 3 clean queries in a row, interval -2s |

Bounds are 5s to 150s for the interval, up to 45s for the timeout. Zero
results counts as success, not a drop -- "that player is offline" is a real
answer, and treating it as a drop would push a realm into needless back-off
just because you whisper offline people.

The learned value is stored in `MessageBoxSettings`, so it persists across
relogs rather than relearning from 30s every session. Per-character saved
vars means each realm keeps its own learned number automatically.

### Controlling it

```
/mbox who              -- show current interval, timeout, mode, queue depth
/mbox who 45           -- pin to 45s, disable adaptive
/mbox who auto         -- back to adaptive
/mbox who reset        -- reset to 30s/10s and clear learned state
/mbox who skip         -- toggle: skip /who entirely when class is already
                          known via ClassicAPI (guild/zone go unresolved)
/mbox who debug        -- print each tuning adjustment as it happens
```

`/mbox who skip` is the one worth knowing about on a hard-throttled realm.
With ClassicAPI installed the class comes back instantly from the whisper's
GUID, and the only thing the follow-up `/who` still buys you is guild and
zone. If your throttle budget is tight, spending it on guild text is
probably not the trade you want.

## Notes / caveats

- None of this touches `MessageBoxDB` or the message-storage format --
  it only affects how fast/how accurately `MessageBox.playerCache` gets
  filled in, using the exact same fields (`class`, `classUpper`, `race`,
  `level`) the stock `/who` handler already writes.
- SuperWoW detection uses the fact that it makes `UnitExists()` return a
  GUID as a second value -- this is version-independent and doesn't rely
  on any particular SuperWoW build string.
- If you don't want the `NP_ChatBubblesWhisper` CVar changed, just
  `/console set NP_ChatBubblesWhisper 0` afterward -- Compat.lua only sets
  it once, the first time it finds Nampower with the CVar still at its
  default of `0`.
- The adaptive throttle only ever *steers* the stock scheduler by writing
  `MessageBox.WHO_INTERVAL` / `WHO_TIMEOUT`. If you remove Compat.lua, those
  revert to tilare's 30/10 on next load and nothing is left behind except
  a few unused keys in `MessageBoxSettings`.
- It can't detect a server that throttles by *silently returning your own
  query as an empty result set* fast enough to look like a legitimate
  "player offline". If a realm does that, pin the interval manually with
  `/mbox who <seconds>`.






