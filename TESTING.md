# Testing report

Everything below is reproducible with `cd tests && lua run_all.lua` (Lua 5.2+ on the host).

## Method

WoW 1.12 cannot be run in CI, so the addon is executed inside a purpose-built simulator
(`tests/harness.lua`):

- **Lua 5.0 surface enforced.** The addon is loaded into an isolated environment exposing only the
  Lua 5.0 library (no `#`, `select`, `string.match`, `math.fmod`, `os`, `xpcall`…), with the legacy
  WoW shims (`table.getn`, `math.mod`, `string.gfind`, `getglobal`, `this`/`arg1`/`event` globals).
  A separate lint (`lint5.lua`) rejects 5.1+ syntax in the shipped files.
- **Faithful failure semantics** for the reported bug: `SetNormalTexture(<missing file>)` makes
  `GetNormalTexture()` return `nil`; `SetFont(<missing file>)` fails and `FontString:SetText` then
  raises `Font not set`. Script errors are caught per handler, as the client does.
- **Virtual clock**, event dispatch, `OnUpdate` ticking, deterministic `time()`.
- **Simulated `/who` server** with configurable minimum gap, reply latency, silent-drop vs
  stale-redelivery, and a "strict" mode where every attempt resets the lockout.
- **Mock client mods**, individually switchable: ClassicAPI (chat GUID, player cache, silent who,
  5 s cooldown), UnitXP SP3 (`nop` / `notify`), Nampower (file I/O, CVars, `GetUnitGUID`),
  SuperWoW, WeirdUtils. API semantics follow each mod's own documentation.
- **A/B reference**: the untouched upstream sources (`tests/baseline/`) run the identical scripted
  sessions as the patched addon.

## Results

| Suite | What it proves | Result |
|---|---|---|
| `lint5.lua` | No Lua 5.1+ constructs in the shipped files | clean |
| `syn.lua` | All files parse | OK |
| `t_repro.lua` | Original + missing `img/` `font/` raises **exactly** `UI.lua:786` then `UI.lua:1117: Font not set` (the reported errors, same call chains); original + assets present is clean; patched is clean in all 4 asset/Compat combinations | 7/7 |
| `t_regress.lua` | One 120+ s whisper session (in/out whispers, GM, AFK, offline system message, window toggles, who queue) replayed on original, patched, and patched+Compat under **no mods / each mod / all mods / assets missing**: conversations and unread counts are byte-identical to upstream in all 10 configurations | 10/10 identical |
| `t_features.lua` | 53 assertions over 16 feature groups, each with a negative control where meaningful (below) | 53/53 |
| `t_soak.lua` | 4 × 6,000 randomized steps (whispers, GMs, offline players, slash commands incl. `who` tuning, server-policy changes, targets) with invariants checked every step: interval/timeout in range, queue ≤ max, conversation arrays in sync, `SendWho` restored | 0 errors, 0 violations |
| mutation check | 15 deliberate re-introductions of fixed bugs / removed features, each in a scratch copy | 15/15 detected |

### Feature groups (`t_features.lua`)
F1 ClassicAPI GUID resolution · F2 visible-unit resolution (no mods) · F3 persistent name-cache fallback ·
F4 wrong-GUID rejection · F5 silent `/who` + friends-panel suppression window · F6 UnitXP flash / opt-in sound ·
F7 Nampower bubbles opt-in & non-destructive · F8 WeirdUtils log · F9 deDE class token (control: upstream
stores `MAGIER`) · F10 fault isolation (client mod throws, whisper still stored) · F11 slash commands (stock
verbs untouched) · F12 skip-`/who` option · F13 slow realm (control: stock resolves 0/6) · F14 40 s throttle
(control: stock wastes more queries) · F15 learned interval persists across sessions, `SendWho` restored ·
F16 known GMs never resolved or queried.

### Mutations that must be (and are) caught
Font fallback reverted · bell nil-guard reverted · UnitXP detected by return value instead of `pcall` flag ·
GUID ownership check removed · bubbles on by default · late-reply penalty not undone · timeout not raised on
late reply · late data not harvested · no back-off on timeout · `SendWho` not restored · Compat `pcall`
removed · token normalisation off · learned interval not persisted · skip option ignored · GMs resolved.

## Back-to-back: stock vs adaptive `/who` (`t_throttle.lua`)

40 contacts whisper at t=0; 2400 simulated seconds; "resolved" = class + guild known;
"all-class" = every contact has a class (with ClassicAPI this is immediate).

```
permissive realm      (no limit, 0.3s)
   variant              resolved  class-only t(50%)    t(100%)   all-class  sent   dropped  final int/timeout
   stock                40/40     0          572s      1172s     1172s      40     0        30s/10s
   adaptive             40/40     0          310s      510s      510s       40     0        10s/10s
   adaptive+ClassicAPI  40/40     0          310s      510s      1s         40     0        10s/10s

throttled 12s, silent drop
   variant              resolved  class-only t(50%)    t(100%)   all-class  sent   dropped  final int/timeout
   stock                40/40     0          572s      1172s     1172s      40     0        30s/10s
   adaptive             40/40     0          383s      647s      647s       42     2        12s/10s
   adaptive+ClassicAPI  40/40     0          383s      647s      1s         42     2        12s/10s

throttled 25s, silent drop
   variant              resolved  class-only t(50%)    t(100%)   all-class  sent   dropped  final int/timeout
   stock                40/40     0          572s      1172s     1172s      40     0        30s/10s
   adaptive             40/40     0          624s      1164s     1164s      42     2        26s/10s
   adaptive+ClassicAPI  40/40     0          624s      1164s     1s         42     2        26s/10s

throttled 40s, silent drop
   variant              resolved  class-only t(50%)    t(100%)   all-class  sent   dropped  final int/timeout
   stock                34/40     0          1351s     never     never      68     34       30s/10s
   adaptive             40/40     0          956s      1816s     1816s      42     2        42s/10s
   adaptive+ClassicAPI  40/40     0          956s      1816s     1s         42     2        42s/10s

throttled 25s, stale re-delivery
   variant              resolved  class-only t(50%)    t(100%)   all-class  sent   dropped  final int/timeout
   stock                40/40     0          572s      1172s     1172s      40     0        30s/10s
   adaptive             40/40     0          602s      1142s     1142s      42     2        26s/10s
   adaptive+ClassicAPI  40/40     0          602s      1142s     1s         42     2        26s/10s

slow realm (replies after 14s)
   variant              resolved  class-only t(50%)    t(100%)   all-class  sent   dropped  final int/timeout
   stock                0/40      0          never     never     never      59     0        30s/10s
   adaptive             40/40     0          378s      658s      658s       40     0        10s/21s
   adaptive+ClassicAPI  40/40     0          378s      658s      1s         40     0        10s/21s

strict 20s (any attempt resets lockout)
   variant              resolved  class-only t(50%)    t(100%)   all-class  sent   dropped  final int/timeout
   stock                40/40     0          572s      1172s     1172s      40     0        30s/10s
   adaptive             40/40     0          472s      892s      892s       41     1        20s/10s
   adaptive+ClassicAPI  40/40     0          472s      892s      1s         41     1        20s/10s

```

Reading it honestly:

- Clear wins at the extremes: stricter-than-stock throttles (stock leaves 6/40 unresolved after 34 wasted
  queries), slow realms (stock 0/40), and unthrottled realms (about 2.3× faster to drain).
- No meaningful gain when the realm limit is just under 30 s (25 s row), and a small cost: two probe drops
  while it learns. Stock is fine there.
- The simulator's throttle models are simple. Real servers may add behaviours it can't represent
  (e.g. disconnect-on-flood), which is why the interval floor defaults to a conservative 10 s.

## Tracing (`/mbox trace`, captured by `t_trace.lua`)

```
### 1. resolver paths (ClassicAPI present)
  1000.0 resolve Bob via unit:target
  1000.0 resolve Alice via guid
  1000.0 resolve Alice via name-cache
  1000.0 resolve Stranger via none
  1000.0 resolve Alice via cached

### 2. adaptation on a realm that drops /who closer than 25s
  1000.0 resolve P1 via none
  1000.0 resolve P2 via none
  1000.0 resolve P3 via none
  1000.0 resolve P4 via none
  1000.0 resolve P5 via none
  1000.0 resolve P6 via none
  1000.0 resolve P7 via none
  1000.0 resolve P8 via none
  1001.0 who sent for P1
  1031.0 who sent for P2
  1032.0 who healthy: interval 30.0 -> 25.5
  1057.0 who sent for P3
  1083.0 who sent for P4
  1084.0 who healthy: interval 25.5 -> 21.7
  1105.0 who sent for P5
  1116.0 who timeout: interval 21.7 -> 32.5 (floor 23.8)
  1149.0 who sent for P6
  1182.0 who sent for P7
  1183.0 who healthy: interval 32.5 -> 27.6
  1210.0 who sent for P8
  1238.0 who sent for P5
  1239.0 who healthy: interval 27.6 -> 23.8

### 3. slow realm (replies after 14s, stock timeout 10s)
  1000.0 resolve P1 via none
  1000.0 resolve P2 via none
  1000.0 resolve P3 via none
  1000.0 resolve P4 via none
  1001.0 who sent for P1
  1012.0 who timeout: interval 30.0 -> 45.0 (floor 33.0)
  1015.0 who late reply 14.0s: timeout=21.0 interval=30.0
  1042.0 who sent for P2
  1072.0 who sent for P3
  1086.0 who healthy: interval 30.0 -> 25.5
  1098.0 who sent for P4

```

1. **Resolver order**: visible unit → chat GUID → persistent name cache → none; already-cached and GM
   contacts short-circuit.
2. **Throttled realm (25 s)**: the controller probes downward (30→25.5→21.7), gets a drop at 21.7
   (`timeout: 21.7 -> 32.5`, floor 23.8), then settles near the real limit instead of oscillating.
3. **Slow realm**: the 14 s reply is first counted as a timeout, then recognised as a *late reply*
   (`late reply 14.0s: timeout=21.0 interval=30.0`): the interval penalty is undone, the timeout
   raised, and the data kept, so there is no re-query.

## Defects found in my earlier draft of Compat.lua (now fixed and covered by tests)

1. UnitXP detection required the function's *return value* to be `true`; the wiki's check is the
   `pcall` success flag, so UnitXP would have been reported absent.
2. `hasNampower` was read at file load, before upstream sets it at `PLAYER_LOGIN`.
3. `UnitGUID` was assumed to exist everywhere; it is provided by ClassicAPI, with `GetUnitGUID`
   (Nampower) / `UnitExists` 2nd return (SuperWoW) as alternatives.
4. `NP_ChatBubblesWhisper` (default `0`) was force-enabled on every login. Now opt-in and reversible.
5. A GUID from the chat event was trusted blindly; now verified against the contact's name.
6. A wrong guess about the `/who` late-reply case left good replies discarded; now harvested.

## What this does not prove

- Behaviour on a live client, a specific realm's `/who` policy, or a specific mod build.
- That `GetCurrentChatGUID()` is populated for `CHAT_MSG_WHISPER_INFORM` (the docs describe incoming
  chat generally); the name check and name-cache fallback make a miss harmless.
- Rendering. The simulator checks that UI code runs and handles missing assets, not how it looks.
