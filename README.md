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

`InpUltraOpenMode` is on by default in `v1.0.7_10`. The strict continuation, pullback, and
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

- `InpQuickBasketProfitUSD` (`0.25`) closes the basket the moment net profit reaches it.
- `InpUseProfitLock` arms once basket profit passes `InpProfitLockTriggerUSD` (`0.15`) and
  closes if profit falls `InpProfitLockGiveBackUSD` (`0.08`) back from its peak. The cycle
  logs this as exit reason `profit_lock`, and the dashboard shows the running peak.
- `InpUseTrailingStop` moves the broker-side stop: to entry plus
  `InpBreakEvenLockPoints` once `InpBreakEvenPoints` of profit exist, then trailing
  `InpTrailingStopPoints` behind price once `InpTrailingStartPoints` is reached. This
  requires `InpUseHardStops`, since it modifies the SL that hard stops attach.

## Gold only

`InpRestrictToGold` is on by default in `v1.0.7_10`. `OnInit` returns `INIT_FAILED` on any
chart whose symbol does not contain a fragment from `InpGoldSymbols` (`XAU,GOLD`), which
covers `XAUUSD`, `XAUUSD.m`, `GOLD`, and `GOLDmicro`. Add your broker's spelling to that
list, or set `InpRestrictToGold=false` to trade anything again.

Because gold is quoted with 2 or 3 digits depending on the broker, a fixed point count for
TP/SL fits only one of them. `InpUseAtrStops` (default on) sizes both from ATR instead:
`TP = ATR x InpAtrTpFactor`, `SL = ATR x InpAtrSlFactor`, both clamped between
`InpAtrMinStopPoints` and `InpAtrMaxStopPoints`. Factors default to `1.5` / `1.5`, so the
reward-to-risk starts at 1:1 and the dashboard shows the resolved point values live.
Set `InpUseAtrStops=false` to go back to the fixed `InpTakeProfitPoints` / `InpStopLossPoints`.

## Cent accounts

Cent accounts report profit in cents, so a `0.25` target would otherwise mean a quarter of
a cent. The EA reads `ACCOUNT_CURRENCY` at init and, for `USC`, `USDC`, `EUC`, `EURC`,
`RUC`, `GBC`, or anything containing `CENT`, scales every money input by 100. Every USD
field — `Target USD`, `Quick target USD`, `Max loss USD`, and the profit lock — therefore
means real USD on both account types. `InpMoneyScaleOverride` forces the multiplier if your
broker uses a currency code the auto-detection misses. The dashboard shows the detected
currency and multiplier, and lot sizes are unaffected since `NormalizeVolume` already
follows the broker's own min/step/max.

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

- `Allow recovery` is off by default in `v1.0.7_10`, so the bot takes one shot and lets TP/SL/loss cap handle the outcome.
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
- `Max loss USD` is an optional dashboard emergency close. Keep it `0` to disable it. (Before `v1.0.7_10` a dashboard `0` silently fell back to the EA input instead of disabling.)

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

The current app version is `v1.0.7` and the current EA build is `v1.0.7_10`. The live MT5 file stays named `volatilty.ex5`, and each successful compile also archives a versioned copy such as `builds\volatilty_v1.0.7_10.ex5`. The dashboard shows both the compiled build version and the version reported by the running EA.

To create the next build later, bump `EA_BUILD_NUMBER` near the top of `volatilty.mq5`, then run `.\build_ea.ps1` again.

## AI training

The trainer writes `recovery_shield_model.txt` atomically so the EA does not read a partial model. When enough rows exist, it trains a profit-weighted logistic filter and, if there is enough history for validation, chooses the decision threshold from recent closed cycles. Set `MODEL_THRESHOLD` to force your own threshold instead.

## Personal server deployment

Yes, this can run on a personal server. The simplest reliable setup is a Windows VPS with MetaTrader 5 logged in and the Django dashboard running on the same machine so both share the MT5 Common Files folder.

For server mode, set these environment variables before starting Django:

```powershell
$env:DJANGO_DEBUG = "0"
$env:DJANGO_SECRET_KEY = "replace-with-a-long-random-secret"
$env:DJANGO_ALLOWED_HOSTS = "127.0.0.1,localhost,your-domain-or-server-ip"
$env:MT5_COMMON_FILES_DIR = "$env:APPDATA\MetaQuotes\Terminal\Common\Files"
```

Keep the dashboard behind a firewall, VPN, or reverse proxy with authentication. The dashboard can start, pause, and close positions, so do not expose it directly to the public internet.

For a quick private run:

```powershell
.\mq5_v_env\Scripts\python.exe manage.py migrate
.\mq5_v_env\Scripts\python.exe manage.py collectstatic --noinput
.\mq5_v_env\Scripts\python.exe manage.py runserver 127.0.0.1:8000 --noreload
```

Use a process manager on the server so both MT5 and the dashboard restart after reboots.
