# MT5 Recovery Shield

Small Django dashboard and training helper for a MetaTrader 5 recovery bot demo setup.

## What is included

- A browser dashboard for start, pause, and close-all commands
- File-based status polling from the MT5 common files directory
- A simple training script that builds a lightweight trade filter from closed cycles

## Quick start

Double-click `start.bat`. It creates the virtual environment on first run, installs
requirements, applies migrations, starts the server, and opens the dashboard in your
browser once it answers.

```text
start.bat            Start the dashboard and open it
start.bat build      Compile the EA into MT5 first, then start
start.bat lan        Bind 0.0.0.0 so another machine can reach it
```

`start.bat lan` also sets `DJANGO_ALLOWED_HOSTS=*` when you have not set it yourself; without
that Django answers every non-localhost address with HTTP 400. LAN mode turns on sign-in
(`DASHBOARD_REQUIRE_LOGIN`): the first run asks you to create an account, or reads
`DASHBOARD_USER` and `DASHBOARD_PASSWORD` if you set them. Five failed attempts from one
address lock sign-in for five minutes. Use LAN mode only on a network you trust.

`DASHBOARD_HOST` and `DASHBOARD_PORT` still override the defaults if you set them first.
Point MT5 shared files at the same common files directory used by the app.

## MT5 files

Set `MT5_COMMON_FILES_DIR` when you want the dashboard and trainer to read from a custom shared folder instead of the default MetaTrader common files path.

Set `MODEL_THRESHOLD` if you want the trainer to write a different decision cutoff into the generated model file.

## Faster EA loop

The EA keeps trading decisions on ticks, but slow shared-file reads are throttled with `InpControlPollSeconds`, status writes with `InpStatusWriteSeconds`, and the ATR/MA/RSI feature calculations are cached from indicator buffers. Keep `InpControlPollSeconds=1` for a dashboard that still reacts quickly without doing file I/O on every market tick.

`InpTimerMilliseconds` (default `100`) drives a millisecond heartbeat so the EA keeps
evaluating entries, trailing stops, and the profit lock between ticks instead of once per
second. The dashboard polls its status endpoint every 750 ms.

## Ultra open mode

`InpUltraOpenMode` is on by default in `v1.0.7_11`. The strict continuation, pullback, and
scalp patterns are still tried first; when they disagree the EA falls back to a much
looser call that takes any small confirmed push (`InpUltraMinMovePoints`,
`InpUltraMinBodyPoints`) as long as RSI is not at an extreme. Spread inflates the required
move far less in this mode (`InpUltraSpreadMoveFactor`, `0.05` instead of `0.20`).

Entry throttles were loosened to match: `InpMinSecondsBetweenTrades=1`,
`InpScalpMaxClosedTrades=200`, `InpLossPauseSeconds=20`, `InpEntryMinMovePoints=8`,
`InpMaxSpread=300`. Turn `InpUltraOpenMode` off to return to the stricter `v1.0.7_8`
behaviour without changing anything else.

## Profit capture

Three independent exits now take money off the table:

- `InpQuickBasketProfitUSD` (`0.75`) closes the basket the moment net profit reaches it.
- `InpUseProfitLock` arms once basket profit passes `InpProfitLockTriggerUSD` (`0.15`) and
  closes if profit falls `InpProfitLockGiveBackUSD` (`0.08`) back from its peak. The cycle
  logs this as exit reason `profit_lock`, and the dashboard shows the running peak.
- `InpUseTrailingStop` moves the broker-side stop: to entry plus
  `InpBreakEvenLockPoints` once `InpBreakEvenPoints` of profit exist, then trailing
  `InpTrailingStopPoints` behind price once `InpTrailingStartPoints` is reached. This
  requires `InpUseHardStops`, since it modifies the SL that hard stops attach.

## Gold only

`InpRestrictToGold` is on by default in `v1.0.7_11`. `OnInit` returns `INIT_FAILED` on any
chart whose symbol does not contain a fragment from `InpGoldSymbols` (`XAU,GOLD`), which
covers `XAUUSD`, `XAUUSD.m`, `GOLD`, and `GOLDmicro`. Add your broker's spelling to that
list, or set `InpRestrictToGold=false` to trade anything again.

Because gold is quoted with 2 or 3 digits depending on the broker, a fixed point count for
TP/SL fits only one of them. `InpUseAtrStops` (default on) sizes both from ATR instead:
`TP = ATR x InpAtrTpFactor`, `SL = ATR x InpAtrSlFactor`, both clamped between
`InpAtrMinStopPoints` and `InpAtrMaxStopPoints`. Factors default to `1.5` / `1.5`, so the
reward-to-risk starts at 1:1 and the dashboard shows the resolved point values live.
Set `InpUseAtrStops=false` to go back to the fixed `InpTakeProfitPoints` / `InpStopLossPoints`.

That ATR is read from `InpEntryTrendTimeframe` (M1), not from the chart timeframe. Sizing M1
scalps off an H1 or D1 ATR produced an 11,000 point value that saturated the clamp and pinned
both TP and SL to the 3000 point ceiling, which silently ignored the dashboard TP/SL entirely.
The dashboard reports `entry_atr_points` so the number driving the stops is visible.

## Cent accounts

Cent accounts report profit in cents, so a `0.25` target would otherwise mean a quarter of
a cent. The EA reads `ACCOUNT_CURRENCY` at init and, for `USC`, `USDC`, `EUC`, `EURC`,
`RUC`, `GBC`, or anything containing `CENT`, scales every money input by 100. Every USD
field — `Target USD`, `Quick target USD`, `Max loss USD`, and the profit lock — therefore
means real USD on both account types. `InpMoneyScaleOverride` forces the multiplier if your
broker uses a currency code the auto-detection misses. The dashboard shows the detected
currency and multiplier, and lot sizes are unaffected since `NormalizeVolume` already
follows the broker's own min/step/max.

## Spread economics

Spread is a fixed cost paid on every entry, and it decides whether a target is reachable at
all. On `XAUUSDm` at 240 points of spread, a `0.15` quick target is 150 points on `0.01`
lots — the spread is 1.6x the entire profit target, so the trade is behind before it starts.
`v1.0.7_11` makes this structural rather than a setting you have to get right by hand:

- `InpScaleTargetsToSpread` raises a too-small quick target until it is at least
  `InpTargetSpreadMultiple` (`3.0`) times the current spread. The dashboard shows both the
  requested and the effective target.
- `InpMaxLossToTargetRatio` (`1.5`) caps the loss stop relative to that effective target, so
  a `0.75` target cannot sit behind a `2.00` loss cap. Wins and losses stay the same order of
  magnitude, which is what decides the break-even win rate.
- `InpScalpMaxSpreadTpRatio` now measures spread against the distance the trade *actually*
  travels before closing (usually the quick target), not the broker take profit that rarely
  fires. Before this it compared against a 3000 point TP and passed everything.

The break-even win rate is `avg_loss / (avg_loss + avg_win)`. At `+0.26` versus `-1.41` that
is 84.6%; at `+0.75` versus `-1.10` it is 59.5%.

## Backtesting

The EA detects the Strategy Tester and runs on its own inputs there. Dashboard control,
status writes, and the AI gate are all bypassed, so a backtest does not need Django
running and will not sit paused waiting for a control file.

- `InpUseAiFilterInBacktest` (default `false`) keeps the model from blocking entries during
  a backtest. Set it `true` if you specifically want to test the trained filter.
- Cycle and event CSVs are still written, so backtests generate training rows. They land in
  the same files as live trading; change `InpCycleLogFile` in the tester inputs if you want
  them kept separate.
- Sweep `InpAtrTpFactor` and `InpAtrSlFactor` first. They set the reward-to-risk shape, which
  matters more than any other input. `InpScalpMaxSpreadTpRatio` is second: spread is a fixed
  cost paid on every entry, so a high ratio means most winners cannot cover it.

## Aggressive mode

The EA can close baskets fast with `Quick target USD`, which is separate from the larger `Target USD`. When `InpAggressiveMode=true`, the bot closes all managed positions as soon as the basket net profit reaches the quick target, then waits for the next entry. This is safer than closing only winning positions and leaving losing hedge legs behind.

The recovery logic now also has guardrails:

- `Allow recovery` is off by default in `v1.0.7_11`, so the bot takes one shot and lets TP/SL/loss cap handle the outcome.
- `InpFastScalpMode` allows fast continuation scalps, but same-side entries cool down after a stop loss.
- `InpScalpMaxSpreadTpRatio` blocks 0.50 scalps when spread is too large relative to the take-profit distance.
- `InpUseTrendEntry` now uses fast M1 continuation and pullback entries instead of selling only because a slower MA is stale.
- `Take profit points` and `Stop loss points` attach hard broker-side exits to each order when hard stops are enabled.
- `InpMinSecondsBetweenTrades` prevents duplicate orders from tick/timer events.
- `InpUseTrendEntry` starts new cycles in the confirmed fast trend direction.
- `InpBlockCounterTrendRecovery` blocks recovery trades that fight a strong MA trend.
- `Max lot` caps the recovery lot so a bad cycle cannot jump from small lots to oversized exposure.
- `Max same side` limits how many buys or sells can stack in one basket.
- `Min same-side distance` blocks another buy/sell if it is too close to an existing position of the same type.
- `InpMaxConsecutiveLosses`, `InpLossPauseSeconds`, and `InpLossSideCooldownSeconds` pause the bot after stop-loss streaks.
- `Max loss USD` is the dashboard emergency close. A dashboard `0` no longer falls back to the EA input (that was fixed in `v1.0.7_11`), but with the default `InpMaxLossToTargetRatio=1.5` the EA still enforces a cap of effective target x 1.5 so the downside stays proportional to the upside. To run with no loss cap at all, set both `Max loss USD` to `0` and `InpMaxLossToTargetRatio` to `0`.

For aggressive demo scalping, use a small quick target such as `0.50` to `2.00`, a low initial lot, and a realistic max spread for the symbol.

## EA build automation

Use the build helper instead of manually copying `volatilty.mq5` into MetaTrader. It copies the EA source into `MQL5\Experts\RecoveryShield`, keeps a `.bak` of the previous target file, and compiles it with MetaEditor when MetaEditor can be found.

```powershell
.\build_ea.ps1
```

Run this while editing if you want automatic rebuilds:

```powershell
.\build_ea.ps1 -Watch
```

If auto-detection picks the wrong terminal, set the paths explicitly:

```powershell
$env:MT5_EXPERTS_DIR = "C:\Users\you\AppData\Roaming\MetaQuotes\Terminal\<terminal-id>\MQL5\Experts"
$env:METAEDITOR_EXE = "C:\Program Files\MetaTrader 5\metaeditor64.exe"
.\build_ea.ps1
```

You can also set `MT5_DATA_DIR` to the terminal data folder and the script will use its `MQL5\Experts` directory.

Use `.\build_ea.ps1 -NoCompile` if you only want to sync the source and compile from MetaEditor yourself.

The current app version is `v1.0.7` and the current EA build is `v1.0.7_18`. The live MT5 file stays named `volatilty.ex5`, and each successful compile also archives a versioned copy such as `builds\volatilty_v1.0.7_18.ex5`. The repository does not ship a compiled `volatilty.ex5`; run `start.bat build` or `build_ea.ps1` to produce one that matches the source. The dashboard shows both the compiled build version and the version reported by the running EA.

To create the next build later, bump `EA_BUILD_NUMBER` near the top of `volatilty.mq5`, then run `.\build_ea.ps1` again.

## AI training

Every finished basket is written to `recovery_shield_cycles.csv`, whether the EA closed it (`quick_target`, `profit_lock`, `max_loss`, `timeout`, `dashboard_close_all`) or it disappeared on its own through a broker TP/SL, a trailing stop, or a manual close (`external_close`, profit taken from the last basket value the EA saw). Rows without a readable `exit_profit` are skipped by the trainer, never counted as wins. Only the most recent 5000 rows are used, so training stays well inside the dashboard's 900 second limit however long the log grows.

The trainer writes `recovery_shield_model.txt` atomically so the EA does not read a partial model. When enough rows exist, it trains a profit-weighted logistic filter and, if there is enough history for validation, chooses the decision threshold from recent closed cycles. Set `MODEL_THRESHOLD` to force your own threshold instead.

## Personal server deployment

Yes, this can run on a personal server. The simplest reliable setup is a Windows VPS with MetaTrader 5 logged in and the Django dashboard running on the same machine so both share the MT5 Common Files folder.

For server mode, set these environment variables before starting Django:

```powershell
$env:DJANGO_SECRET_KEY = "replace-with-a-long-random-secret"
$env:DJANGO_ALLOWED_HOSTS = "127.0.0.1,localhost,your-domain-or-server-ip"
$env:MT5_COMMON_FILES_DIR = "$env:APPDATA\MetaQuotes\Terminal\Common\Files"
```

Keep the dashboard behind a firewall, VPN, or reverse proxy with authentication. The dashboard can start, pause, and close positions, so do not expose it directly to the public internet.

Defaults are production-safe: `DJANGO_DEBUG` is off, and static files are served by WhiteNoise.
If `DJANGO_SECRET_KEY` is not set, a random key is generated once and stored in
`.django_secret_key` (git-ignored).

- Cookies become secure-only when `DJANGO_SECURE_SSL_REDIRECT=1`. Override with `DJANGO_SESSION_COOKIE_SECURE` and `DJANGO_CSRF_COOKIE_SECURE`.
- `DJANGO_TRUST_PROXY_SSL_HEADER=1` is only for a reverse proxy that sets `X-Forwarded-Proto`.
- Sign-in turns on automatically when `DJANGO_ALLOWED_HOSTS` contains anything other than localhost. Force it with `DASHBOARD_REQUIRE_LOGIN=1`.

For a quick private run:

```powershell
.\mq5_v_env\Scripts\python.exe manage.py migrate
.\mq5_v_env\Scripts\python.exe manage.py collectstatic --noinput
.\mq5_v_env\Scripts\python.exe manage.py runserver 127.0.0.1:8000 --noreload --insecure
```

Use a process manager on the server so both MT5 and the dashboard restart after reboots.

## Changelog

### v1.0.7_18

EA (`volatilty.mq5`, rebuild and reattach it; the dashboard shows a version mismatch until you do):

- A cycle's realized profit no longer includes the previous cycle's exit deal. When a new entry opened in the same server second as the last exit, the old deal fell inside the new cycle's history window and corrupted its training row. Deals are now filtered by millisecond time against the last finished cycle.
- The loss-streak counter now includes the deal fee, the same as the cycle profit.
- Inputs are validated on start: `TargetUSD` must be above zero (zero closed every basket the moment it was not losing), `MaxTurns` at least `1`, and `InpMaxSpread` above zero (zero blocked every entry).
- An unused helper function was removed.

Dashboard and tooling:

- `.gitignore` now really ignores `.django_secret_key`, `staticfiles/` and `*.ex5`, as the earlier notes claimed. The stray `volatilty.ex5` is no longer in the project; build one with `start.bat build` or `build_ea.ps1`. If the file is already tracked, run `git rm --cached volatilty.ex5` once.
- The WhiteNoise warning `No directory at: staticfiles/` no longer prints on every start.
- `Validation profit` and `Validation baseline avg` are separate tiles. They shared one block before.
- The top bar keeps the status pill on the same row as the title when `Sign out` is shown.
- README figures that had drifted from the code were corrected: the quick target default, the trainer time limit and the current build number.
- New tests cover input validation, the cycle profit filter, the ignore list and the tile layout.

### v1.0.7_17

EA (`volatilty.mq5`, rebuild and reattach it; the dashboard shows a version mismatch until you do):

- Cycle profit in the training CSV and event log is now the realized result from the deal history (profit, commission, swap, fee). It falls back to the last floating value, tagged `(floating estimate)`, only if the exit deal is not in history yet.
- Close All no longer makes the EA rewrite the control file. The dashboard owns that file; the EA echoes the command's `updated_at` stamp as `close_all_ack` in the status file, so a setting saved at the same moment can no longer be overwritten.
- New `InpMaxDailyLossUSD` (default 5.0, 0 disables): new entries stop for the rest of the server day once realized losses for this symbol and magic reach the limit.
- Ultra Open mode now needs both the minimum move and the minimum body, a close on the right side of the fast MA, and a spread-scaled minimum move. Its RSI blocks default to 85 and 15 so they actually apply.
- Every entry RSI limit and the strict and pullback move factors are now inputs (group `Entry RSI Limits`) with the old values as defaults.
- The effective spread limit (the lower of `InpMaxSpread` and the scalp spread gate) is shown on the chart and in the dashboard spread check.
- Inputs are validated on start, and a failed indicator handle stops the EA with a clear message.
- EA input defaults for multiplier, quick target, loss cap and recovery lot now equal the dashboard defaults, and a test keeps them in sync.

Dashboard and tooling:

- Sign-in (Django accounts) is required automatically for any non-localhost `DJANGO_ALLOWED_HOSTS`, with a five-failure lockout. `start.bat` creates the first account.
- `DJANGO_DEBUG` now defaults to off, static files are served by WhiteNoise, and a random secret key is generated and stored in `.django_secret_key` when none is set.
- The trainer tunes the threshold on one part of the validation rows and judges it on a held-out part. The model is enabled only when the held-out result beats the unfiltered baseline by more than its standard error; otherwise the model file is recording-only.
- The dashboard labels the training figures as in-sample and shows the validation baseline.

### v1.0.7_15

EA (`volatilty.mq5`, rebuild and reattach it; the dashboard shows a version mismatch until you do):

- With `Allow recovery` off, the status now reads `Recovery disabled` while a trade is open. Before, a `Max turns` of `1` logged a `MAX_TURNS_REACHED` event and a "Max turns reached" status on every single cycle even though recovery was never going to run.
- A basket that is closed by the broker within about two seconds of opening no longer loses its cycle row. The EA now finishes and logs that cycle before it starts the next entry, instead of overwriting its state.

Dashboard and tooling:

- `Max lot` must be at least `0.01`. Before, `0` was accepted and silently removed the recovery lot cap.
- The `TP / SL points` tile shows the same value on first load and after each poll (EA resolved value, then the EA reported input, then `-`). Before, the page showed the control file values and the poller replaced them with `-`.
- The `App` version in the page header no longer switches to the running EA's version after the first poll; it keeps showing the compiled app version.
- The trainer uses only the most recent 5000 closed cycles. Training time grows with every row, and a long-running scalper could push the Train Model button past its 300 second timeout.
- `.gitignore` now really ignores `staticfiles/` and `*.ex5`, as the `v1.0.7_14` notes already claimed, and the stray `volatilty.ex5` is no longer in the repository.
- New tests cover the `Max lot` minimum and the trainer row cap.

### v1.0.7_14

EA (`volatilty.mq5`, rebuild and reattach it; the dashboard shows a version mismatch until you do):

- Closing positions no longer depends on the symbol being fully open for trading. Before, a symbol in close-only, long-only or short-only mode stopped the whole engine, so the profit, loss-cap and timeout exits and Close All never ran. Exits now need only the terminal, EA, account and expert permissions and a symbol that is not disabled. New entries and recovery orders still need full trading.
- `InpMaxCycleTime` of `0` or less now disables the timeout. Before, `0` closed every basket the moment it opened.
- Every remaining comment was removed, including the trailing text on `input` lines. MetaTrader labels each setting with that text, so the properties dialog now shows the raw input names such as `InpAtrTpFactor`.

Dashboard and tooling:

- The ATR tile is now `Entry ATR points` and shows `entry_atr_points`, the value that actually sizes the stops, instead of the chart timeframe ATR. New `Requested quick target` and `Target points` tiles show the requested and effective targets that this README already described.
- A control file that cannot be written (permissions, locked folder) now shows an error on the page instead of an HTTP 500, and no success message is shown for a command that was not saved.
- Trainer class weights use the real loss count when a set has no wins.
- `start.bat` prints the real shared folder and honors `MT5_COMMON_FILES_DIR` instead of printing a literal `%APPDATA%`. The failed install message mentions that Django 6 needs Python 3.12 or newer.
- `.gitignore` now ignores `staticfiles/` and `*.ex5`. The stray `volatilty.ex5` that came in the archive was removed; build one from source.
- New tests cover the tiles, control write failures, trainer weights, comment-free EA source, and EA and dashboard version agreement.

### v1.0.7_13

EA (`volatilty.mq5`, rebuild and reattach it; the dashboard shows a version mismatch until you do):

- A close that fails is retried every 2 seconds until every position is gone, even if the exit condition that triggered it no longer holds. Before, it was retried on every 100 ms tick, and a basket could be left half closed once profit moved away from the target.
- A rejected entry or recovery order backs off for 5 seconds. Before, a refused order (market closed, invalid stops) was resent on every timer tick and logged each time.
- Identical `TRADE_FAILURE` events and failed trailing-stop updates are throttled instead of being written on every tick.
- Take profit and stop loss are widened to the broker's minimum stop distance (stops level plus spread for the stop loss), so small ATR-derived stops are no longer rejected with `Invalid stops`.
- Dashboard control reads, status writes, model reads and the on-chart panel are throttled with a real-time clock. They used server time, which stops when the market is closed, so Pause and Close All were never read over the weekend and the status file stopped updating.
- The "trading blocked" branch no longer rewrites the status file on every tick and now reports the real position state.
- The sell-side RSI exhaustion limits mirror the buy side (`12` and `10` instead of `22` for continuation and scalp sells).
- A model file whose vectors do not hold exactly the expected number of values is rejected instead of partly loaded.
- Event messages are made CSV safe, and control values tolerate stray whitespace.

Dashboard and tooling:

- Pause and Close All are always sent. A typo in an unrelated settings field used to block them; now the command goes out and the invalid settings are simply not saved.
- The badge shows `EA Offline` when the status file is older than 15 seconds, instead of staying on `EA Confirmed` after MT5 closes.
- `Allow recovery` is a dropdown instead of a free text box, and the Quick presets say they also send the start command.
- The page and `dashboard.js` no longer invent values (`0.50`, `0.05`, `300`, a hard-coded `v1.0.7_11`) when the EA has not reported them; they show `-`. The poller skips a poll while the previous one is still running.
- Default shared folder and the trainer path are resolved from the project folder, not from the directory the server was started in. The trainer is started with a relative path from the project root.
- The trainer ignores rows whose features are all zero (cycles adopted after a restart in older logs).
- All comments and docstrings were removed from the source. The only `//` text left in `volatilty.mq5` is on `input` lines, because MetaTrader shows it as the label of each setting.

### v1.0.7_12

EA (`volatilty.mq5`, rebuild with `start.bat build` or `build_ea.ps1`):

- Baskets closed by the broker (TP/SL, trailing stop) or by hand are now logged as cycles (`external_close`). Before, only EA-forced exits were recorded, so the AI trained on a biased sample and cycle state went stale.
- A failed close no longer resets the cycle or acknowledges a dashboard close-all. The EA keeps the command pending and retries, and logs the cycle once instead of once per retry.
- A cycle adopted after an EA restart no longer writes an all-zero training row.
- The close-all acknowledgement wrote account-currency amounts back into the USD control file, which multiplied the targets by 100 on cent accounts. It now writes USD.
- The on-chart panel is built as one string. The old `Comment()` call had 71 arguments and MQL5 allows 64.

Dashboard and tooling:

- `NaN`, `Infinity` and huge numbers in the settings form are rejected instead of crashing the page or being written to the control file.
- A failed or timed-out model training now shows the reason on the page, and runs from the project folder regardless of where the server was started.
- Trainer ignores rows with a missing, `nan` or `inf` `exit_profit`.
- `start.bat`: the browser now opens as soon as the server answers (a stray `^` in the PowerShell wait loop made it always wait 10 seconds); `lan` mode works.
- `build_ea.ps1 -Watch` survives a compile error instead of exiting, and refuses to treat a stale EX5 as a fresh build when MetaEditor writes no log.
- `requirements.txt` is plain UTF-8 (it was UTF-16). Version labels in the page come from the backend instead of hard-coded strings, and empty fields show `-` instead of invented numbers.
