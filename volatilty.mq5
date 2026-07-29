//+------------------------------------------------------------------+
//|                                     RecoveryZone_Shielded_V1.mq5 |
//|                                  Copyright 2026, Gemini Academic |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

#define EA_APP_VERSION "v1.0.7"
#define EA_BUILD_NUMBER 11
#define EA_BUILD_VERSION "v1.0.7_11"
#define MODEL_FEATURE_COUNT 10

//--- Input Parameters
input group "Recovery Settings"
input double InitialLot   = 0.01;      // Starting Lot Size
input int    ZoneHeight   = 500;       // Distance between Buy and Sell (Points)
input double Multiplier   = 1.2;       // Recovery Multiplier (e.g. 1.2x)
input double TargetUSD    = 1.0;       // Close all when Net Profit reaches this $ amount
input int    MaxTurns     = 1;         // Max number of cycle trades; 1 disables recovery by position count

input group "Symbol and Account"
input bool   InpRestrictToGold = true;              // Refuse to start on non-gold charts
input string InpGoldSymbols = "XAU,GOLD";           // Comma separated symbol fragments treated as gold
input double InpMoneyScaleOverride = 0.0;           // 0 auto-detects cent accounts; else units per 1 USD

input group "The Shields (Safety Filters)"
input int    InpMaxSpread    = 300;    // Block new cycles above this spread
input int    InpMaxCycleTime = 900;    // Kill the whole cycle if stuck (Seconds)
input int    InpMagic        = 999999;

input group "Aggressive Profit Capture"
input bool   InpAggressiveMode = true;              // Close small basket profits quickly
input double InpQuickBasketProfitUSD = 0.25;        // Fast close-all target; 0 disables
input double InpMaxFloatingLossUSD = 3.0;           // Emergency basket loss cap; 0 disables
input bool   InpUseProfitLock = true;               // Close a winner that starts giving profit back
input double InpProfitLockTriggerUSD = 0.15;        // Arm the lock once basket profit passes this
input double InpProfitLockGiveBackUSD = 0.08;       // Close if profit drops this far below its peak

input group "Spread Economics"
input bool   InpScaleTargetsToSpread = true;        // Raise tiny targets until they clear the spread
input double InpTargetSpreadMultiple = 3.0;         // Profit target must be at least spread x this
input double InpMaxLossToTargetRatio = 1.5;         // Cap the loss stop at target x this
input bool   InpUseTrailingStop = true;             // Move broker stops as price runs in our favour
input int    InpBreakEvenPoints = 60;               // Profit points before the stop moves to entry
input int    InpBreakEvenLockPoints = 10;           // Points locked in at break even
input int    InpTrailingStartPoints = 90;           // Profit points before trailing starts
input int    InpTrailingStopPoints = 45;            // Trailing distance kept behind price
input bool   InpAllowRecovery = false;              // Off by default to avoid stacking losses
input bool   InpUseHardStops = true;                // Attach SL/TP to orders
input int    InpTakeProfitPoints = 200;             // Fixed per-position TP in points; 0 disables
input int    InpStopLossPoints = 300;               // Fixed per-position SL in points; 0 disables
input bool   InpUseAtrStops = true;                 // Size TP/SL from ATR instead of fixed points
input double InpAtrTpFactor = 1.5;                  // TP = ATR x this
input double InpAtrSlFactor = 1.5;                  // SL = ATR x this
input int    InpAtrMinStopPoints = 30;              // Floor for ATR derived stops
input int    InpAtrMaxStopPoints = 3000;            // Ceiling for ATR derived stops

input group "Entry Signal"
input bool   InpUseTrendEntry = true;               // Use the fast trend engine
input bool   InpBlockCounterTrendRecovery = true;   // Do not add recovery trades against strong MA trend
input int    InpTrendFilterPoints = 50;             // MA delta needed to call trend strong
input ENUM_TIMEFRAMES InpEntryTrendTimeframe = PERIOD_M1; // Fast entry trend timeframe
input int    InpEntryTrendLookbackBars = 2;         // Closed bars used for fast entry direction
input int    InpEntryMinMovePoints = 8;             // Minimum fast move before opening a trend trade
input int    InpEntryMinBodyPoints = 1;             // Minimum latest closed candle body
input int    InpEntryFastMaPeriod = 5;              // Fast MA for entry trend
input int    InpEntrySlowMaPeriod = 13;             // Slow MA for entry trend
input int    InpEntryRsiPeriod = 7;                 // RSI used to avoid exhausted entries

input group "Ultra Open Mode"
input bool   InpUltraOpenMode = true;               // Take any small confirmed push instead of waiting
input int    InpUltraMinMovePoints = 4;             // Tiny move that still counts as direction
input int    InpUltraMinBodyPoints = 1;             // Tiny candle body that still counts
input double InpUltraSpreadMoveFactor = 0.05;       // How much spread inflates the move requirement
input double InpUltraRsiBuyBlock = 97.0;            // Only block buys this far into overbought
input double InpUltraRsiSellBlock = 3.0;            // Only block sells this far into oversold

input group "Risk Throttles"
input bool   InpFastScalpMode = true;               // Allow fast continuation scalps
input double InpScalpMaxSpreadTpRatio = 0.50;       // Max spread as a ratio of scalp TP points
input int    InpScalpMaxClosedTrades = 200;         // Pause after N closed scalp trades per window
input int    InpScalpWindowSeconds = 900;           // Scalp burst accounting window
input int    InpMaxConsecutiveLosses = 4;           // Pause after this many losing closes
input int    InpLossPauseSeconds = 20;              // Pause all entries after a loss streak
input int    InpLossSideCooldownSeconds = 20;       // Pause the stopped side after a loss
input int    InpMinSecondsBetweenTrades = 1;        // Trade throttle to prevent duplicate entries
input double InpMaxRecoveryLot = 0.05;              // Cap recovery lot; 0 disables
input int    InpMaxSameSidePositions = 2;           // Max buy or sell positions per cycle; 0 disables
input int    InpMinSameSideDistancePoints = 150;    // Block same-side entries too close to existing positions

input group "Django Dashboard Control"
input bool   InpUseDashboardControl = true;
input string InpControlFile         = "recovery_shield_control.txt";
input string InpStatusFile          = "recovery_shield_status.txt";

input group "Logging and AI Filter"
input bool   InpEnableCsvLogging    = true;
input string InpEventLogFile        = "recovery_shield_events.csv";
input string InpCycleLogFile        = "recovery_shield_cycles.csv";
input bool   InpUseAiFilter         = true;
input bool   InpUseAiFilterInBacktest = false;  // Keep the model gate off while backtesting
input string InpModelFile           = "recovery_shield_model.txt";
input double InpDefaultModelThreshold = 0.55;

input group "Performance"
input int    InpTimerMilliseconds   = 100;      // Engine heartbeat between ticks
input int    InpControlPollSeconds  = 1;        // Read dashboard commands at most once per N seconds
input int    InpStatusWriteSeconds  = 1;        // Write dashboard status at most once per N seconds
input int    InpTradeDeviationPoints = 30;      // Max price deviation used by CTrade

//--- Global Variables
CTrade         trade;
CPositionInfo  m_position;
double         UpperLevel   = 0;
double         LowerLevel   = 0;
int            CurrentTurns = 0;
datetime       CycleStartTime = 0;
string         LastStatus = "Loaded. Waiting for first tick.";
bool           DashboardEnabled = false;
bool           DashboardCloseAll = false;
double         DashboardInitialLot = 0.0;
int            DashboardZoneHeight = 0;
double         DashboardMultiplier = 0.0;
double         DashboardTargetUSD = 0.0;
double         DashboardQuickTargetUSD = -1.0;
double         DashboardMaxLossUSD = -1.0;
int            DashboardAllowRecovery = -1;
int            DashboardTakeProfitPoints = -1;
int            DashboardStopLossPoints = -1;
double         DashboardMaxLot = -1.0;
int            DashboardMaxSameSide = -1;
int            DashboardMinSameSideDistance = -1;
int            DashboardMaxTurns = 0;
int            DashboardMaxSpread = 0;
datetime       LastStatusWrite = 0;
datetime       LastControlRead = 0;
datetime       LastDashboardDraw = 0;
datetime       LastTradeTime = 0;
datetime       LastRecoveryBlockLog = 0;
string         LastEventSource = "init";
string         CycleId = "";
datetime       CycleStartedAt = 0;
double         CycleStartBid = 0.0;
double         CycleStartAsk = 0.0;
int            CycleStartSpread = 0;
double         CycleFeatures[MODEL_FEATURE_COUNT];
double         CycleModelScore = 0.0;
double         CycleWorstProfit = 0.0;
double         CyclePeakProfit = 0.0;
bool           MaxTurnsLogged = false;
bool           TesterMode = false;
double         AccountMoneyScale = 1.0;
string         AccountMoneyLabel = "USD";
bool           ModelFileFound = false;
bool           ModelGateEnabled = false;
int            ModelTrainedRows = 0;
double         ModelThreshold = 0.55;
double         ModelBias = 0.0;
double         ModelMean[MODEL_FEATURE_COUNT];
double         ModelScale[MODEL_FEATURE_COUNT];
double         ModelWeights[MODEL_FEATURE_COUNT];
double         LastModelScore = 0.0;
string         ModelReason = "No model loaded yet.";
datetime       LastModelRead = 0;
datetime       LastModelBlockLog = 0;
int            AtrHandle = INVALID_HANDLE;
int            AtrEntryHandle = INVALID_HANDLE;
int            FastMaHandle = INVALID_HANDLE;
int            SlowMaHandle = INVALID_HANDLE;
int            RsiHandle = INVALID_HANDLE;
bool           FeatureCacheReady = false;
datetime       FeatureCacheBarTime = 0;
double         CachedAtrPoints = 0.0;
double         CachedRangePoints = 0.0;
double         CachedMaDeltaPoints = 0.0;
double         CachedRsi14 = 50.0;
int            LastEntryTrendSignal = 0;
double         LastEntryTrendMovePoints = 0.0;
double         LastEntryTrendBodyPoints = 0.0;
double         LastEntryTrendMaDeltaPoints = 0.0;
double         LastEntryTrendRsi = 50.0;
string         LastEntryTrendReason = "Not checked yet.";
int            ConsecutiveLosses = 0;
datetime       LastLossTime = 0;
int            LastLossSide = 0;
double         LastClosedProfit = 0.0;
datetime       ScalpWindowStart = 0;
int            ScalpClosedTrades = 0;
string         LastScalpRiskReason = "Ready.";

int OnInit() {
   TesterMode = ((bool)MQLInfoInteger(MQL_TESTER) ||
                 (bool)MQLInfoInteger(MQL_OPTIMIZATION) ||
                 (bool)MQLInfoInteger(MQL_VISUAL_MODE));

   if(!SymbolIsAllowed())
   {
      string blocked = _Symbol + " is not a gold symbol. Attach to XAUUSD or set InpRestrictToGold=false.";
      Print("RECOVERY SHIELD: ", blocked);
      Comment("--- RECOVERY SHIELD ---\nBLOCKED\n", blocked);
      return(INIT_FAILED);
   }

   ResolveAccountMoneyScale();
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpTradeDeviationPoints);
   trade.SetAsyncMode(false);
   AtrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   AtrEntryHandle = iATR(_Symbol, InpEntryTrendTimeframe, 14);
   FastMaHandle = iMA(_Symbol, PERIOD_CURRENT, 10, 0, MODE_SMA, PRICE_CLOSE);
   SlowMaHandle = iMA(_Symbol, PERIOD_CURRENT, 30, 0, MODE_SMA, PRICE_CLOSE);
   RsiHandle = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);
   InitializeModelDefaults();
   ReadDashboardControl(true);
   ReadAiModel(true);
   StartEngineTimer();
   SetStatus("EA " + EA_BUILD_VERSION + " initialized on " + _Symbol +
             (DashboardControlActive() ? ". Waiting for dashboard command." : ". Running on local inputs."));
   AppendEvent("EA_INIT", 0, 0.0, "initialized version=" + EA_BUILD_VERSION +
               " symbol=" + _Symbol +
               " currency=" + AccountMoneyLabel +
               " money_scale=" + DoubleToString(AccountMoneyScale, 2));
   Comment("--- RECOVERY SHIELD ---\n",
           "Status: ", LastStatus, "\n",
           "If no trade opens, check the Experts tab.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ReleaseIndicator(AtrHandle);
   ReleaseIndicator(AtrEntryHandle);
   ReleaseIndicator(FastMaHandle);
   ReleaseIndicator(SlowMaHandle);
   ReleaseIndicator(RsiHandle);
   Comment("");
}

//--- Gold-only guard. The fragments in InpGoldSymbols cover broker
//--- variants such as XAUUSD, XAUUSD.m, GOLD and GOLDmicro.
bool SymbolIsAllowed()
{
   if(!InpRestrictToGold)
      return true;

   string upperSymbol = _Symbol;
   StringToUpper(upperSymbol);

   string fragments[];
   int count = StringSplit(InpGoldSymbols, ',', fragments);

   for(int i = 0; i < count; i++)
   {
      string token = fragments[i];
      StringTrimLeft(token);
      StringTrimRight(token);
      StringToUpper(token);

      if(token == "")
         continue;

      if(StringFind(upperSymbol, token) >= 0)
         return true;
   }

   return false;
}

//--- Cent accounts report profit in cents, so USD targets need scaling
//--- before they are compared against basket profit.
void ResolveAccountMoneyScale()
{
   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   AccountMoneyLabel = (currency == "" ? "USD" : currency);

   if(InpMoneyScaleOverride > 0.0)
   {
      AccountMoneyScale = InpMoneyScaleOverride;
      return;
   }

   string upperCurrency = currency;
   StringToUpper(upperCurrency);

   if(upperCurrency == "USC" || upperCurrency == "USDC" || upperCurrency == "EUC" ||
      upperCurrency == "EURC" || upperCurrency == "RUC" || upperCurrency == "GBC" ||
      StringFind(upperCurrency, "CENT") >= 0)
   {
      AccountMoneyScale = 100.0;
      return;
   }

   AccountMoneyScale = 1.0;
}

double ScaledMoney(double usdAmount)
{
   return(usdAmount * AccountMoneyScale);
}

//--- Money and points are not interchangeable across symbols and lot
//--- sizes, so convert explicitly before comparing a USD target to spread.
double PointValuePerLot()
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0 || _Point <= 0.0)
      return 0.0;

   return tickValue * (_Point / tickSize);
}

double MoneyToPoints(double money, double volume)
{
   double perPoint = PointValuePerLot() * volume;

   if(perPoint <= 0.0 || money <= 0.0)
      return 0.0;

   return money / perPoint;
}

double PointsToMoney(double points, double volume)
{
   return points * PointValuePerLot() * volume;
}

//--- Spread is paid on every entry. A target smaller than the spread can
//--- never win often enough, so raise it until it clears the cost.
double EffectiveQuickTargetUSD()
{
   double target = ActiveQuickTargetUSD();

   if(!InpScaleTargetsToSpread || InpTargetSpreadMultiple <= 0.0)
      return target;

   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread <= 0)
      return target;

   double volume = NormalizeVolume(ActiveInitialLot());
   double floorMoney = PointsToMoney(spread * InpTargetSpreadMultiple, volume);

   if(floorMoney > target)
      return floorMoney;

   return target;
}

//--- Keep the downside proportional to the upside. Without this a 0.15
//--- target sat behind a 2.00 loss cap, which needs a 93% win rate.
double EffectiveMaxFloatingLossUSD()
{
   double cap = ActiveMaxFloatingLossUSD();

   if(InpMaxLossToTargetRatio <= 0.0)
      return cap;

   double target = EffectiveQuickTargetUSD();
   if(target <= 0.0)
      return cap;

   double maxCap = target * InpMaxLossToTargetRatio;

   if(cap <= 0.0 || cap > maxCap)
      return maxCap;

   return cap;
}

//--- The distance the basket actually travels before it closes. The quick
//--- target usually fires long before the broker take profit does.
int EffectiveTargetPoints()
{
   int points = ResolveTakeProfitPoints();
   double quickTarget = EffectiveQuickTargetUSD();

   if(InpAggressiveMode && quickTarget > 0.0)
   {
      double quickPoints = MoneyToPoints(quickTarget, NormalizeVolume(ActiveInitialLot()));

      if(quickPoints > 0.0 && (points <= 0 || quickPoints < points))
         points = (int)MathRound(quickPoints);
   }

   return points;
}

//--- ATR sized stops keep gold usable across 2 digit and 3 digit brokers
//--- instead of hard coding a point count that only fits one of them.
int AtrDerivedPoints(double factor, int fallbackPoints)
{
   if(!InpUseAtrStops || factor <= 0.0)
      return fallbackPoints;

   double atrPoints = EntryTimeframeAtrPoints();

   if(atrPoints <= 0.0)
      return fallbackPoints;

   int points = (int)MathRound(atrPoints * factor);

   if(InpAtrMinStopPoints > 0 && points < InpAtrMinStopPoints)
      points = InpAtrMinStopPoints;

   if(InpAtrMaxStopPoints > 0 && points > InpAtrMaxStopPoints)
      points = InpAtrMaxStopPoints;

   return points;
}

int ResolveTakeProfitPoints()
{
   int fixedPoints = ActiveTakeProfitPoints();

   if(fixedPoints <= 0)
      return 0;

   return AtrDerivedPoints(InpAtrTpFactor, fixedPoints);
}

int ResolveStopLossPoints()
{
   int fixedPoints = ActiveStopLossPoints();

   if(fixedPoints <= 0)
      return 0;

   return AtrDerivedPoints(InpAtrSlFactor, fixedPoints);
}

void StartEngineTimer()
{
   int milliseconds = InpTimerMilliseconds;

   if(milliseconds <= 0)
   {
      EventSetTimer(1);
      return;
   }

   if(milliseconds < 20)
      milliseconds = 20;

   if(milliseconds >= 1000)
   {
      EventSetTimer(milliseconds / 1000);
      return;
   }

   EventSetMillisecondTimer(milliseconds);
}

bool DashboardControlActive()
{
   return(InpUseDashboardControl && !TesterMode);
}

bool AiFilterActive()
{
   if(!InpUseAiFilter)
      return false;

   if(TesterMode && !InpUseAiFilterInBacktest)
      return false;

   return true;
}

void OnTick()
{
   RunEngine("tick");
}

void OnTimer()
{
   RunEngine("timer");
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong dealTicket = trans.deal;
   if(dealTicket == 0 || !HistoryDealSelect(dealTicket))
      return;

   string dealSymbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
   if(dealSymbol != _Symbol)
      return;

   long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
   if(magic != InpMagic)
      return;

   ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(dealEntry != DEAL_ENTRY_OUT && dealEntry != DEAL_ENTRY_OUT_BY && dealEntry != DEAL_ENTRY_INOUT)
      return;

   ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
   int closedSide = 0;
   if(dealType == DEAL_TYPE_BUY)
      closedSide = -1;
   else if(dealType == DEAL_TYPE_SELL)
      closedSide = 1;

   double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                   HistoryDealGetDouble(dealTicket, DEAL_COMMISSION) +
                   HistoryDealGetDouble(dealTicket, DEAL_SWAP);

   NoteClosedScalp(profit, closedSide);
}

void RunEngine(string eventSource)
{
   LastEventSource = eventSource;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   ReadDashboardControl(false);
   ReadAiModel(false);

   // 1. DASHBOARD
   DrawDashboard(spread);

   if(!TradingAllowed())
   {
      SetStatus("Trading blocked by terminal, EA settings, account, or symbol mode.");
      DrawDashboard(spread);
      WriteDashboardStatus(spread, false, 0.0, true);
      return;
   }

   // 2. CHECK POSITIONS & PROFIT
   bool hasPosition = false;
   int positionCount = 0;
   double totalProfit = 0;
   ENUM_POSITION_TYPE lastType = (ENUM_POSITION_TYPE)-1;
   ENUM_POSITION_TYPE firstType = (ENUM_POSITION_TYPE)-1;
   datetime firstTime = 0;
   datetime lastTime = 0;
   double firstOpenPrice = 0.0;
   double lastOpenPrice = 0.0;

   GetManagedPositionState(
      hasPosition,
      positionCount,
      totalProfit,
      firstType,
      firstTime,
      firstOpenPrice,
      lastType,
      lastTime,
      lastOpenPrice
   );
   SyncCycleFromPositions(hasPosition, positionCount, firstType, firstTime, firstOpenPrice, bid, ask, spread);

   if(hasPosition && CycleId != "")
   {
      if(totalProfit < CycleWorstProfit)
         CycleWorstProfit = totalProfit;

      if(totalProfit > CyclePeakProfit)
         CyclePeakProfit = totalProfit;
   }

   if(DashboardCloseAll)
   {
      if(hasPosition)
      {
         SetStatus("Dashboard close-all command received.");
         FinishCycle("dashboard_close_all", spread, totalProfit);
         CloseAll();
         ResetEA();
      }
      else
      {
         SetStatus("Dashboard close-all command received. No positions found.");
      }

      AcknowledgeCloseAllCommand();
      WriteDashboardStatus(spread, false, 0.0, true);
      return;
   }

   // 3. EMERGENCY EXIT (Profit Target OR Time-Out)
   if(hasPosition) {
      bool timeOut = (TimeCurrent() - CycleStartTime >= InpMaxCycleTime);
      bool hitQuickTarget = (InpAggressiveMode &&
                             EffectiveQuickTargetUSD() > 0.0 &&
                             totalProfit >= EffectiveQuickTargetUSD());
      bool hitNormalTarget = (totalProfit >= ActiveTargetUSD());
      bool hitLossCap = (EffectiveMaxFloatingLossUSD() > 0.0 &&
                         totalProfit <= -EffectiveMaxFloatingLossUSD());
      bool hitProfitLock = ProfitLockTriggered(totalProfit);

      if(hitNormalTarget || hitQuickTarget || hitProfitLock || hitLossCap || timeOut) {
         if(timeOut) Print("SHIELD: Cycle timed out. Closing to prevent 24hr trap.");
         if(hitLossCap) Print("SHIELD: Max floating loss hit. Closing basket.");

         string exitReason = "target";
         if(hitQuickTarget)
            exitReason = "quick_target";
         if(hitProfitLock)
            exitReason = "profit_lock";
         if(hitLossCap)
            exitReason = "max_loss";
         if(timeOut)
            exitReason = "timeout";

         FinishCycle(exitReason, spread, totalProfit);
         CloseAll();
         ResetEA();
         WriteDashboardStatus(spread, false, 0.0, true);
         return;
      }

      ManageOpenPositions(bid, ask);
   }

   // 4. INITIAL ENTRY (With Spread Filter)
   if(!hasPosition)
   {
      if(!DashboardEnabled)
      {
         SetStatus("Paused. Click Start EA in the Django dashboard.");
         DrawDashboard(spread);
         WriteDashboardStatus(spread, hasPosition, totalProfit);
         return;
      }

      if(spread > ActiveMaxSpread())
      {
         SetStatus("Waiting: spread is above the max allowed.");
         DrawDashboard(spread);
         WriteDashboardStatus(spread, hasPosition, totalProfit);
         return; // DON'T start a new cycle during high spread!
      }

      if(!ScalpSpreadAllowsEntry(spread))
      {
         DrawDashboard(spread);
         WriteDashboardStatus(spread, hasPosition, totalProfit);
         return;
      }

      double modelScore = 0.0;
      if(!AiAllowsEntry(spread, modelScore))
      {
         DrawDashboard(spread);
         WriteDashboardStatus(spread, hasPosition, totalProfit);
         return;
      }

      if(!CanTradeNow())
      {
         WriteDashboardStatus(spread, hasPosition, totalProfit);
         return;
      }

      ENUM_POSITION_TYPE entryType = POSITION_TYPE_BUY;
      if(!InitialEntrySignal(entryType, spread))
      {
         DrawDashboard(spread);
         WriteDashboardStatus(spread, hasPosition, totalProfit);
         return;
      }

      if(!ScalpRiskAllowsEntry(entryType))
      {
         SetStatus(LastScalpRiskReason);
         DrawDashboard(spread);
         WriteDashboardStatus(spread, hasPosition, totalProfit);
         return;
      }

      double entryLot = NormalizeVolume(ActiveInitialLot());
      double stopLoss = 0.0;
      double takeProfit = 0.0;
      BuildOrderStops(entryType, entryType == POSITION_TYPE_SELL ? bid : ask, stopLoss, takeProfit);
      bool orderSent = false;

      if(entryType == POSITION_TYPE_SELL)
         orderSent = trade.Sell(entryLot, _Symbol, bid, stopLoss, takeProfit);
      else
         orderSent = trade.Buy(entryLot, _Symbol, ask, stopLoss, takeProfit);

      if(orderSent)
      {
         if(TradeSucceeded())
         {
            ConfigureCycleLevels(entryType, entryType == POSITION_TYPE_SELL ? bid : ask);
            CurrentTurns = 1;
            CycleStartTime = TimeCurrent();
            LastTradeTime = TimeCurrent();
            StartCycle(bid, ask, spread, modelScore);
            SetStatus(entryType == POSITION_TYPE_SELL ? "Initial SELL opened." : "Initial BUY opened.");
            AppendEvent(entryType == POSITION_TYPE_SELL ? "TRADE_SELL" : "TRADE_BUY",
                        spread,
                        CurrentManagedProfit(),
                        "initial_lot=" + DoubleToString(entryLot, 2) +
                        " trend=" + EntryTrendLabel() +
                        " reason=" + LastEntryTrendReason);
         }
         else
         {
            LogTradeFailure(entryType == POSITION_TYPE_SELL ? "Initial SELL" : "Initial BUY");
         }
      }
      else
      {
         LogTradeFailure(entryType == POSITION_TYPE_SELL ? "Initial SELL" : "Initial BUY");
      }
      WriteDashboardStatus(spread, HasManagedPosition(), CurrentManagedProfit(), true);
      return;
   }

   // 5. RECOVERY LOGIC
   if(!DashboardEnabled)
   {
      SetStatus("Paused with open positions. Profit and timeout exits are still monitored.");
      WriteDashboardStatus(spread, hasPosition, totalProfit);
      return;
   }

   if(CurrentTurns < ActiveMaxTurns())
   {
      if(!ActiveAllowRecovery())
      {
         SetStatus("Recovery disabled. Waiting for TP, SL, quick target, or loss cap.");
         WriteDashboardStatus(spread, hasPosition, totalProfit);
         return;
      }

      if(CanTradeNow())
      {
         if(bid <= LowerLevel && lastType == POSITION_TYPE_BUY)
         {
            if(!RecoveryExposureAllows(POSITION_TYPE_SELL, bid, spread, totalProfit))
            {
               WriteDashboardStatus(spread, hasPosition, totalProfit);
               return;
            }

            double nextLot = NextRecoveryLot();
            double stopLoss = 0.0;
            double takeProfit = 0.0;
            BuildOrderStops(POSITION_TYPE_SELL, bid, stopLoss, takeProfit);

            if(trade.Sell(nextLot, _Symbol, bid, stopLoss, takeProfit) && TradeSucceeded())
            {
               CurrentTurns++;
               LastTradeTime = TimeCurrent();
               SetStatus("Recovery SELL opened.");
               AppendEvent("TRADE_SELL", spread, totalProfit, "recovery_lot=" + DoubleToString(nextLot, 2));
            }
            else
            {
               LogTradeFailure("Recovery SELL");
            }
         }
      
         if(ask >= UpperLevel && lastType == POSITION_TYPE_SELL)
         {
            if(!RecoveryExposureAllows(POSITION_TYPE_BUY, ask, spread, totalProfit))
            {
               WriteDashboardStatus(spread, hasPosition, totalProfit);
               return;
            }

            double nextLot = NextRecoveryLot();
            double stopLoss = 0.0;
            double takeProfit = 0.0;
            BuildOrderStops(POSITION_TYPE_BUY, ask, stopLoss, takeProfit);

            if(trade.Buy(nextLot, _Symbol, ask, stopLoss, takeProfit) && TradeSucceeded())
            {
               CurrentTurns++;
               LastTradeTime = TimeCurrent();
               SetStatus("Recovery BUY opened.");
               AppendEvent("TRADE_BUY", spread, totalProfit, "recovery_lot=" + DoubleToString(nextLot, 2));
            }
            else
            {
               LogTradeFailure("Recovery BUY");
            }
         }
      }
   }
   else if(!MaxTurnsLogged)
   {
      MaxTurnsLogged = true;
      SetStatus("Max turns reached. Waiting for target, timeout, or manual close.");
      AppendEvent("MAX_TURNS_REACHED", spread, totalProfit, "max_turns=" + IntegerToString(ActiveMaxTurns()));
   }

   WriteDashboardStatus(spread, hasPosition, totalProfit);
}

void CloseAll() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == InpMagic)
      {
         if(!trade.PositionClose(m_position.Ticket()) || !TradeSucceeded())
            LogTradeFailure("Close position");
      }
   }
}

bool ProfitLockTriggered(double totalProfit)
{
   if(!InpUseProfitLock)
      return false;

   double trigger = ScaledMoney(InpProfitLockTriggerUSD);
   if(trigger <= 0.0 || CyclePeakProfit < trigger)
      return false;

   double giveBack = ScaledMoney(InpProfitLockGiveBackUSD);
   if(giveBack <= 0.0)
      giveBack = trigger * 0.5;

   if(totalProfit > CyclePeakProfit - giveBack)
      return false;

   Print("SHIELD: Profit lock hit. Peak ", DoubleToString(CyclePeakProfit, 2),
         " now ", DoubleToString(totalProfit, 2));

   return true;
}

void ManageOpenPositions(double bid, double ask)
{
   if(!InpUseTrailingStop || !InpUseHardStops || _Point <= 0.0)
      return;

   if(InpBreakEvenPoints <= 0 && InpTrailingStartPoints <= 0)
      return;

   double minDistance = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double tolerance = _Point / 2.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i) || m_position.Symbol() != _Symbol || m_position.Magic() != InpMagic)
         continue;

      ulong ticket = m_position.Ticket();
      ENUM_POSITION_TYPE positionType = m_position.PositionType();
      double openPrice = m_position.PriceOpen();
      double currentStop = m_position.StopLoss();
      double takeProfit = m_position.TakeProfit();

      if(positionType == POSITION_TYPE_BUY)
      {
         double profitPoints = (bid - openPrice) / _Point;
         double newStop = currentStop;

         if(InpBreakEvenPoints > 0 && profitPoints >= InpBreakEvenPoints)
         {
            double breakEven = NormalizeDouble(openPrice + (InpBreakEvenLockPoints * _Point), _Digits);
            if(breakEven > newStop)
               newStop = breakEven;
         }

         if(InpTrailingStartPoints > 0 && InpTrailingStopPoints > 0 && profitPoints >= InpTrailingStartPoints)
         {
            double trailStop = NormalizeDouble(bid - (InpTrailingStopPoints * _Point), _Digits);
            if(trailStop > newStop)
               newStop = trailStop;
         }

         if(newStop > currentStop + tolerance && (bid - newStop) > minDistance)
         {
            if(!trade.PositionModify(ticket, newStop, takeProfit) || !TradeSucceeded())
               LogTradeFailure("Trailing stop BUY");
         }
      }
      else if(positionType == POSITION_TYPE_SELL)
      {
         double profitPoints = (openPrice - ask) / _Point;
         double effectiveStop = (currentStop > 0.0 ? currentStop : DBL_MAX);
         double newStop = effectiveStop;

         if(InpBreakEvenPoints > 0 && profitPoints >= InpBreakEvenPoints)
         {
            double breakEven = NormalizeDouble(openPrice - (InpBreakEvenLockPoints * _Point), _Digits);
            if(breakEven < newStop)
               newStop = breakEven;
         }

         if(InpTrailingStartPoints > 0 && InpTrailingStopPoints > 0 && profitPoints >= InpTrailingStartPoints)
         {
            double trailStop = NormalizeDouble(ask + (InpTrailingStopPoints * _Point), _Digits);
            if(trailStop < newStop)
               newStop = trailStop;
         }

         if(newStop < effectiveStop - tolerance && (newStop - ask) > minDistance)
         {
            if(!trade.PositionModify(ticket, newStop, takeProfit) || !TradeSucceeded())
               LogTradeFailure("Trailing stop SELL");
         }
      }
   }
}

void ReleaseIndicator(int &handle)
{
   if(handle != INVALID_HANDLE)
   {
      IndicatorRelease(handle);
      handle = INVALID_HANDLE;
   }
}

void ResetEA() {
   UpperLevel = 0; LowerLevel = 0; CurrentTurns = 0; CycleStartTime = 0;
   CycleId = "";
   CycleStartedAt = 0;
   CycleStartBid = 0.0;
   CycleStartAsk = 0.0;
   CycleStartSpread = 0;
   CycleModelScore = 0.0;
   CycleWorstProfit = 0.0;
   CyclePeakProfit = 0.0;
   MaxTurnsLogged = false;

   for(int i = 0; i < MODEL_FEATURE_COUNT; i++)
      CycleFeatures[i] = 0.0;
}

bool HasManagedPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == InpMagic)
         return true;
   }

   return false;
}

double CurrentManagedProfit()
{
   double totalProfit = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == InpMagic)
         totalProfit += m_position.Profit() + m_position.Commission() + m_position.Swap();
   }

   return totalProfit;
}

void GetManagedPositionState(
   bool &hasPosition,
   int &positionCount,
   double &totalProfit,
   ENUM_POSITION_TYPE &firstType,
   datetime &firstTime,
   double &firstOpenPrice,
   ENUM_POSITION_TYPE &lastType,
   datetime &lastTime,
   double &lastOpenPrice
)
{
   hasPosition = false;
   positionCount = 0;
   totalProfit = 0.0;
   firstType = (ENUM_POSITION_TYPE)-1;
   lastType = (ENUM_POSITION_TYPE)-1;
   firstTime = 0;
   lastTime = 0;
   firstOpenPrice = 0.0;
   lastOpenPrice = 0.0;
   ulong firstTicket = 0;
   ulong lastTicket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i) || m_position.Symbol() != _Symbol || m_position.Magic() != InpMagic)
         continue;

      datetime positionTime = (datetime)PositionGetInteger(POSITION_TIME);
      ulong positionTicket = (ulong)PositionGetInteger(POSITION_TICKET);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE positionType = m_position.PositionType();

      hasPosition = true;
      positionCount++;
      totalProfit += m_position.Profit() + m_position.Commission() + m_position.Swap();

      if(firstTime == 0 || positionTime < firstTime || (positionTime == firstTime && positionTicket < firstTicket))
      {
         firstTime = positionTime;
         firstTicket = positionTicket;
         firstType = positionType;
         firstOpenPrice = openPrice;
      }

      if(lastTime == 0 || positionTime > lastTime || (positionTime == lastTime && positionTicket > lastTicket))
      {
         lastTime = positionTime;
         lastTicket = positionTicket;
         lastType = positionType;
         lastOpenPrice = openPrice;
      }
   }
}

void SyncCycleFromPositions(
   bool hasPosition,
   int positionCount,
   ENUM_POSITION_TYPE firstType,
   datetime firstTime,
   double firstOpenPrice,
   double bid,
   double ask,
   int spread
)
{
   if(!hasPosition)
      return;

   if(CurrentTurns < positionCount)
      CurrentTurns = positionCount;

   if(CycleStartTime == 0)
      CycleStartTime = firstTime > 0 ? firstTime : TimeCurrent();

   if(CycleStartedAt == 0)
      CycleStartedAt = CycleStartTime;

   if(CycleStartBid <= 0.0)
      CycleStartBid = bid;

   if(CycleStartAsk <= 0.0)
      CycleStartAsk = ask;

   if(CycleStartSpread <= 0)
      CycleStartSpread = spread;

   if(CycleId == "")
      CycleId = IntegerToString((long)CycleStartTime) + "_" + _Symbol + "_" + IntegerToString(InpMagic);

   if((UpperLevel <= 0.0 || LowerLevel <= 0.0) && firstOpenPrice > 0.0)
      ConfigureCycleLevels(firstType, firstOpenPrice);
}

void ConfigureCycleLevels(ENUM_POSITION_TYPE entryType, double entryPrice)
{
   if(entryType == POSITION_TYPE_SELL)
   {
      LowerLevel = entryPrice;
      UpperLevel = entryPrice + (ActiveZoneHeight() * _Point);
   }
   else
   {
      UpperLevel = entryPrice;
      LowerLevel = entryPrice - (ActiveZoneHeight() * _Point);
   }
}

void BuildOrderStops(ENUM_POSITION_TYPE entryType, double entryPrice, double &stopLoss, double &takeProfit)
{
   stopLoss = 0.0;
   takeProfit = 0.0;

   if(!InpUseHardStops || _Point <= 0.0)
      return;

   int takeProfitPoints = ResolveTakeProfitPoints();
   int stopLossPoints = ResolveStopLossPoints();

   if(entryType == POSITION_TYPE_SELL)
   {
      if(stopLossPoints > 0)
         stopLoss = NormalizeDouble(entryPrice + (stopLossPoints * _Point), _Digits);
      if(takeProfitPoints > 0)
         takeProfit = NormalizeDouble(entryPrice - (takeProfitPoints * _Point), _Digits);
   }
   else
   {
      if(stopLossPoints > 0)
         stopLoss = NormalizeDouble(entryPrice - (stopLossPoints * _Point), _Digits);
      if(takeProfitPoints > 0)
         takeProfit = NormalizeDouble(entryPrice + (takeProfitPoints * _Point), _Digits);
   }
}

bool InitialEntrySignal(ENUM_POSITION_TYPE &entryType, int spread)
{
   if(!InpUseTrendEntry)
   {
      entryType = POSITION_TYPE_BUY;
      LastEntryTrendSignal = 1;
      LastEntryTrendReason = "Trend entry disabled; default BUY.";
      return true;
   }

   int signal = FastEntryTrendSignal(spread);
   if(signal > 0)
   {
      entryType = POSITION_TYPE_BUY;
      return true;
   }

   if(signal < 0)
   {
      entryType = POSITION_TYPE_SELL;
      return true;
   }

   SetStatus("Waiting: no fast trend confirmation. " + LastEntryTrendReason);
   return false;
}

int FastEntryTrendSignal(int spread)
{
   LastEntryTrendSignal = 0;
   LastEntryTrendMovePoints = 0.0;
   LastEntryTrendBodyPoints = 0.0;
   LastEntryTrendMaDeltaPoints = 0.0;
   LastEntryTrendRsi = 50.0;
   LastEntryTrendReason = "Not checked yet.";

   if(_Point <= 0.0)
   {
      LastEntryTrendReason = "Symbol point size unavailable.";
      return 0;
   }

   ENUM_TIMEFRAMES timeframe = InpEntryTrendTimeframe;
   int lookbackBars = InpEntryTrendLookbackBars;
   if(lookbackBars < 2)
      lookbackBars = 2;

   int barsAvailable = Bars(_Symbol, timeframe);
   if(barsAvailable < lookbackBars + 20)
   {
      LastEntryTrendReason = "Waiting for enough fast timeframe bars.";
      return 0;
   }

   double latestClose = iClose(_Symbol, timeframe, 1);
   double lookbackClose = iClose(_Symbol, timeframe, lookbackBars + 1);
   double latestOpen = iOpen(_Symbol, timeframe, 1);

   if(latestClose <= 0.0 || lookbackClose <= 0.0 || latestOpen <= 0.0)
   {
      LastEntryTrendReason = "Fast timeframe price data unavailable.";
      return 0;
   }

   LastEntryTrendMovePoints = (latestClose - lookbackClose) / _Point;
   LastEntryTrendBodyPoints = (latestClose - latestOpen) / _Point;

   int bullishBars = 0;
   int bearishBars = 0;
   bool risingCloses = true;
   bool fallingCloses = true;

   for(int shift = 1; shift <= lookbackBars; shift++)
   {
      double closeNow = iClose(_Symbol, timeframe, shift);
      double closePrevious = iClose(_Symbol, timeframe, shift + 1);
      double openNow = iOpen(_Symbol, timeframe, shift);

      if(closeNow <= 0.0 || closePrevious <= 0.0 || openNow <= 0.0)
      {
         LastEntryTrendReason = "Fast trend candles unavailable.";
         return 0;
      }

      if(closeNow > openNow)
         bullishBars++;
      else if(closeNow < openNow)
         bearishBars++;

      if(closeNow <= closePrevious)
         risingCloses = false;

      if(closeNow >= closePrevious)
         fallingCloses = false;
   }

   double fastMa = SimpleMaOnTimeframe(timeframe, InpEntryFastMaPeriod);
   double slowMa = SimpleMaOnTimeframe(timeframe, InpEntrySlowMaPeriod);
   if(fastMa <= 0.0 || slowMa <= 0.0)
   {
      LastEntryTrendReason = "Fast trend moving averages unavailable.";
      return 0;
   }

   LastEntryTrendMaDeltaPoints = (fastMa - slowMa) / _Point;
   LastEntryTrendRsi = CalculateRsiOnTimeframe(timeframe, InpEntryRsiPeriod);

   double minMovePoints = (double)InpEntryMinMovePoints;
   if(minMovePoints < 1.0)
      minMovePoints = 1.0;

   double spreadMoveFactor = InpUltraOpenMode ? InpUltraSpreadMoveFactor : 0.20;
   if(spreadMoveFactor < 0.0)
      spreadMoveFactor = 0.0;

   double spreadAdjustedMove = (double)spread * spreadMoveFactor;
   if(spreadAdjustedMove > minMovePoints)
      minMovePoints = spreadAdjustedMove;

   double minBodyPoints = (double)InpEntryMinBodyPoints;
   if(minBodyPoints < 0.0)
      minBodyPoints = 0.0;

   bool enoughBullishBars = (bullishBars >= MathMax(1, lookbackBars - 1));
   bool enoughBearishBars = (bearishBars >= MathMax(1, lookbackBars - 1));

   bool buyContinuation = LastEntryTrendMovePoints >= minMovePoints &&
                          LastEntryTrendBodyPoints >= minBodyPoints &&
                          LastEntryTrendMaDeltaPoints > 0.0 &&
                          latestClose > fastMa &&
                          (risingCloses || enoughBullishBars) &&
                          LastEntryTrendRsi <= 88.0;

   bool sellContinuation = LastEntryTrendMovePoints <= -minMovePoints &&
                           LastEntryTrendBodyPoints <= -minBodyPoints &&
                           LastEntryTrendMaDeltaPoints < 0.0 &&
                           latestClose < fastMa &&
                           (fallingCloses || enoughBearishBars) &&
                           LastEntryTrendRsi >= 22.0;

   bool buyPullback = LastEntryTrendMaDeltaPoints >= minMovePoints &&
                      LastEntryTrendMovePoints <= -(minMovePoints * 0.35) &&
                      LastEntryTrendBodyPoints <= -minBodyPoints &&
                      latestClose > slowMa &&
                      LastEntryTrendRsi >= 38.0 &&
                      LastEntryTrendRsi <= 78.0;

   bool sellPullback = LastEntryTrendMaDeltaPoints <= -minMovePoints &&
                       LastEntryTrendMovePoints >= (minMovePoints * 0.35) &&
                       LastEntryTrendBodyPoints >= minBodyPoints &&
                       latestClose < slowMa &&
                       LastEntryTrendRsi >= 22.0 &&
                       LastEntryTrendRsi <= 62.0;

   bool scalpBuy = InpFastScalpMode &&
                   LastEntryTrendMovePoints >= minMovePoints &&
                   LastEntryTrendBodyPoints >= minBodyPoints &&
                   latestClose > fastMa &&
                   enoughBullishBars &&
                   LastEntryTrendRsi <= 90.0;

   bool scalpSell = InpFastScalpMode &&
                    LastEntryTrendMovePoints <= -minMovePoints &&
                    LastEntryTrendBodyPoints <= -minBodyPoints &&
                    latestClose < fastMa &&
                    enoughBearishBars &&
                    LastEntryTrendRsi >= 22.0;

   LastEntryTrendReason = "move=" + DoubleToString(LastEntryTrendMovePoints, 1) +
                          " body=" + DoubleToString(LastEntryTrendBodyPoints, 1) +
                          " ma_delta=" + DoubleToString(LastEntryTrendMaDeltaPoints, 1) +
                          " rsi=" + DoubleToString(LastEntryTrendRsi, 1);

   if(buyContinuation && !sellContinuation)
   {
      LastEntryTrendSignal = 1;
      LastEntryTrendReason = "continuation_buy " + LastEntryTrendReason;
      return 1;
   }

   if(sellContinuation && !buyContinuation)
   {
      LastEntryTrendSignal = -1;
      LastEntryTrendReason = "continuation_sell " + LastEntryTrendReason;
      return -1;
   }

   if(buyPullback && !sellPullback)
   {
      LastEntryTrendSignal = 1;
      LastEntryTrendReason = "pullback_buy " + LastEntryTrendReason;
      return 1;
   }

   if(sellPullback && !buyPullback)
   {
      LastEntryTrendSignal = -1;
      LastEntryTrendReason = "pullback_sell " + LastEntryTrendReason;
      return -1;
   }

   if(scalpBuy && !scalpSell)
   {
      LastEntryTrendSignal = 1;
      LastEntryTrendReason = "fast_scalp_buy " + LastEntryTrendReason;
      return 1;
   }

   if(scalpSell && !scalpBuy)
   {
      LastEntryTrendSignal = -1;
      LastEntryTrendReason = "fast_scalp_sell " + LastEntryTrendReason;
      return -1;
   }

   int ultraSignal = UltraOpenSignal(latestClose, fastMa);
   if(ultraSignal != 0)
   {
      LastEntryTrendSignal = ultraSignal;
      LastEntryTrendReason = (ultraSignal > 0 ? "ultra_open_buy " : "ultra_open_sell ") + LastEntryTrendReason;
      return ultraSignal;
   }

   LastEntryTrendReason = "wait " + LastEntryTrendReason;
   return 0;
}

//--- Last-chance direction call so the EA keeps taking small pushes
//--- instead of standing flat whenever the strict patterns disagree.
int UltraOpenSignal(double latestClose, double fastMa)
{
   if(!InpUltraOpenMode)
      return 0;

   double minMove = (double)InpUltraMinMovePoints;
   if(minMove < 1.0)
      minMove = 1.0;

   double minBody = (double)InpUltraMinBodyPoints;
   if(minBody < 0.0)
      minBody = 0.0;

   bool buyPush = (LastEntryTrendMovePoints >= minMove || LastEntryTrendBodyPoints >= minBody);
   bool sellPush = (LastEntryTrendMovePoints <= -minMove || LastEntryTrendBodyPoints <= -minBody);

   if(buyPush && sellPush)
   {
      // Both sides showed something, so let the candle body break the tie.
      buyPush = (LastEntryTrendBodyPoints > 0.0);
      sellPush = (LastEntryTrendBodyPoints < 0.0);

      if(!buyPush && !sellPush)
      {
         buyPush = (latestClose > fastMa);
         sellPush = (latestClose < fastMa);
      }
   }

   if(buyPush && LastEntryTrendRsi < InpUltraRsiBuyBlock)
      return 1;

   if(sellPush && LastEntryTrendRsi > InpUltraRsiSellBlock)
      return -1;

   return 0;
}

string EntryTrendLabel()
{
   if(LastEntryTrendSignal > 0)
      return "BUY";

   if(LastEntryTrendSignal < 0)
      return "SELL";

   return "WAIT";
}

int PositionTypeSide(ENUM_POSITION_TYPE positionType)
{
   if(positionType == POSITION_TYPE_BUY)
      return 1;

   if(positionType == POSITION_TYPE_SELL)
      return -1;

   return 0;
}

string SideLabel(int side)
{
   if(side > 0)
      return "BUY";

   if(side < 0)
      return "SELL";

   return "NONE";
}

void RefreshScalpWindow()
{
   int windowSeconds = InpScalpWindowSeconds;
   if(windowSeconds < 60)
      windowSeconds = 60;

   if(ScalpWindowStart == 0 || TimeCurrent() - ScalpWindowStart >= windowSeconds)
   {
      ScalpWindowStart = TimeCurrent();
      ScalpClosedTrades = 0;
   }
}

void NoteClosedScalp(double profit, int closedSide)
{
   RefreshScalpWindow();
   ScalpClosedTrades++;
   LastClosedProfit = profit;

   if(profit < 0.0)
   {
      ConsecutiveLosses++;
      LastLossTime = TimeCurrent();
      LastLossSide = closedSide;
      LastScalpRiskReason = "Loss noted on " + SideLabel(closedSide) +
                            ". Streak=" + IntegerToString(ConsecutiveLosses) +
                            " profit=" + DoubleToString(profit, 2);
   }
   else
   {
      ConsecutiveLosses = 0;
      LastScalpRiskReason = "Win noted. Last profit=" + DoubleToString(profit, 2);
   }
}

bool ScalpRiskAllowsEntry(ENUM_POSITION_TYPE entryType)
{
   RefreshScalpWindow();

   int maxClosedTrades = InpScalpMaxClosedTrades;
   if(maxClosedTrades > 0 && ScalpClosedTrades >= maxClosedTrades)
   {
      LastScalpRiskReason = "Scalp burst complete: " + IntegerToString(ScalpClosedTrades) +
                            "/" + IntegerToString(maxClosedTrades) + " closed trades. Waiting for next window.";
      return false;
   }

   datetime now = TimeCurrent();
   int maxLosses = InpMaxConsecutiveLosses;
   if(maxLosses < 1)
      maxLosses = 1;

   int lossPauseSeconds = InpLossPauseSeconds;
   if(lossPauseSeconds < 0)
      lossPauseSeconds = 0;

   if(ConsecutiveLosses >= maxLosses && LastLossTime > 0 && now - LastLossTime < lossPauseSeconds)
   {
      int waitLeft = lossPauseSeconds - (int)(now - LastLossTime);
      LastScalpRiskReason = "Paused after " + IntegerToString(ConsecutiveLosses) +
                            " losses. Resume in " + IntegerToString(waitLeft) + "s.";
      return false;
   }

   int sideCooldownSeconds = InpLossSideCooldownSeconds;
   if(sideCooldownSeconds < 0)
      sideCooldownSeconds = 0;

   int entrySide = PositionTypeSide(entryType);
   if(sideCooldownSeconds > 0 &&
      LastLossTime > 0 &&
      LastLossSide != 0 &&
      entrySide == LastLossSide &&
      now - LastLossTime < sideCooldownSeconds)
   {
      int waitLeft = sideCooldownSeconds - (int)(now - LastLossTime);
      LastScalpRiskReason = SideLabel(entrySide) + " paused after stop loss. Try opposite signal or wait " +
                            IntegerToString(waitLeft) + "s.";
      return false;
   }

   LastScalpRiskReason = "Scalp risk OK.";
   return true;
}

bool ScalpSpreadAllowsEntry(int spread)
{
   if(!InpFastScalpMode)
      return true;

   // Compare spread against the distance the trade really travels before
   // it closes, not the broker take profit that almost never fires.
   int targetPoints = EffectiveTargetPoints();
   if(targetPoints <= 0)
      return true;

   double ratio = InpScalpMaxSpreadTpRatio;
   if(ratio <= 0.0)
      return true;

   if(ratio > 1.0)
      ratio = 1.0;

   int scalpSpreadLimit = (int)MathFloor(targetPoints * ratio);
   if(scalpSpreadLimit < 1)
      return true;

   if(spread <= scalpSpreadLimit)
      return true;

   SetStatus("Waiting: spread " + IntegerToString(spread) +
             " is too high for a " + IntegerToString(targetPoints) +
             " point target (limit " + IntegerToString(scalpSpreadLimit) + ").");
   LastScalpRiskReason = "Spread too high for the current profit target.";
   return false;
}

bool CanTradeNow()
{
   int waitSeconds = InpMinSecondsBetweenTrades;
   if(waitSeconds < 0)
      waitSeconds = 0;

   if(waitSeconds == 0 || LastTradeTime == 0)
      return true;

   int elapsed = (int)(TimeCurrent() - LastTradeTime);
   if(elapsed >= waitSeconds)
      return true;

   SetStatus("Waiting for trade cooldown before opening another order.");
   return false;
}

double NextRecoveryLot()
{
   double volume = ActiveInitialLot() * MathPow(ActiveMultiplier(), CurrentTurns);
   double maxLot = ActiveMaxLot();

   if(maxLot > 0.0 && volume > maxLot)
      volume = maxLot;

   return NormalizeVolume(volume);
}

int CountManagedPositionsByType(ENUM_POSITION_TYPE positionType)
{
   int count = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) &&
         m_position.Symbol() == _Symbol &&
         m_position.Magic() == InpMagic &&
         m_position.PositionType() == positionType)
         count++;
   }

   return count;
}

bool HasNearbyManagedPosition(ENUM_POSITION_TYPE positionType, double price, int distancePoints)
{
   if(distancePoints <= 0 || _Point <= 0.0)
      return false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!m_position.SelectByIndex(i) ||
         m_position.Symbol() != _Symbol ||
         m_position.Magic() != InpMagic ||
         m_position.PositionType() != positionType)
         continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double distance = MathAbs(price - openPrice) / _Point;

      if(distance < distancePoints)
         return true;
   }

   return false;
}

bool RecoveryExposureAllows(ENUM_POSITION_TYPE recoveryType, double price, int spread, double totalProfit)
{
   if(!TrendAllowsRecovery(recoveryType, spread, totalProfit))
      return false;

   string side = recoveryType == POSITION_TYPE_SELL ? "SELL" : "BUY";
   int maxSameSide = ActiveMaxSameSidePositions();

   if(maxSameSide > 0 && CountManagedPositionsByType(recoveryType) >= maxSameSide)
   {
      string message = "Recovery " + side + " blocked: same-side limit reached.";
      SetStatus(message);
      LogRecoveryBlock(spread, totalProfit, message);
      return false;
   }

   int distancePoints = ActiveMinSameSideDistancePoints();
   if(HasNearbyManagedPosition(recoveryType, price, distancePoints))
   {
      string message = "Recovery " + side + " blocked: too close to an existing " + side + ".";
      SetStatus(message);
      LogRecoveryBlock(spread, totalProfit, message);
      return false;
   }

   return true;
}

void LogRecoveryBlock(int spread, double totalProfit, string message)
{
   if(LastRecoveryBlockLog == 0 || TimeCurrent() - LastRecoveryBlockLog >= 30)
   {
      LastRecoveryBlockLog = TimeCurrent();
      AppendEvent("RECOVERY_BLOCKED", spread, totalProfit, message);
   }
}

bool TrendAllowsRecovery(ENUM_POSITION_TYPE recoveryType, int spread, double totalProfit)
{
   if(!InpBlockCounterTrendRecovery)
      return true;

   RefreshFeatureCache(false);
   int trendPoints = InpTrendFilterPoints;
   if(trendPoints < 1)
      trendPoints = 1;
   bool blocked = false;

   if(recoveryType == POSITION_TYPE_SELL && CachedMaDeltaPoints > trendPoints)
      blocked = true;

   if(recoveryType == POSITION_TYPE_BUY && CachedMaDeltaPoints < -trendPoints)
      blocked = true;

   if(!blocked)
      return true;

   string side = recoveryType == POSITION_TYPE_SELL ? "SELL" : "BUY";
   string message = "Recovery " + side + " blocked by trend filter. Holding basket.";
   SetStatus(message);
   LogRecoveryBlock(spread, totalProfit, message + " ma_delta=" + DoubleToString(CachedMaDeltaPoints, 1));

   return false;
}

void InitializeModelDefaults()
{
   ModelFileFound = false;
   ModelGateEnabled = false;
   ModelTrainedRows = 0;
   ModelThreshold = InpDefaultModelThreshold;
   ModelBias = 0.0;
   LastModelScore = 0.0;
   ModelReason = "No model file yet. Recording data.";

   for(int i = 0; i < MODEL_FEATURE_COUNT; i++)
   {
      ModelMean[i] = 0.0;
      ModelScale[i] = 1.0;
      ModelWeights[i] = 0.0;
   }
}

void ReadAiModel(bool forceRead)
{
   if(!AiFilterActive())
   {
      ModelGateEnabled = false;
      ModelReason = (TesterMode && InpUseAiFilter)
                    ? "AI filter off for backtest. Still recording cycles."
                    : "AI filter disabled in EA inputs.";
      return;
   }

   if(!forceRead && LastModelRead != 0 && TimeCurrent() - LastModelRead < 5)
      return;

   LastModelRead = TimeCurrent();

   int handle = FileOpen(InpModelFile,
                         FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_ANSI);

   if(handle == INVALID_HANDLE)
   {
      InitializeModelDefaults();
      return;
   }

   bool enabled = false;
   bool hasMean = false;
   bool hasScale = false;
   bool hasWeights = false;
   ModelFileFound = true;
   ModelGateEnabled = false;
   ModelReason = "Model file found, but not active.";
   ModelThreshold = InpDefaultModelThreshold;
   ModelBias = 0.0;
   ModelTrainedRows = 0;

   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      int equalsAt = StringFind(line, "=");

      if(equalsAt <= 0)
         continue;

      string key = StringSubstr(line, 0, equalsAt);
      string value = StringSubstr(line, equalsAt + 1);

      if(key == "enabled")
         enabled = IsTrueValue(value);
      else if(key == "threshold")
         ModelThreshold = StringToDouble(value);
      else if(key == "bias")
         ModelBias = StringToDouble(value);
      else if(key == "trained_rows")
         ModelTrainedRows = (int)StringToInteger(value);
      else if(key == "reason")
         ModelReason = value;
      else if(key == "mean")
         hasMean = ParseDoubleList(value, ModelMean, MODEL_FEATURE_COUNT);
      else if(key == "scale")
         hasScale = ParseDoubleList(value, ModelScale, MODEL_FEATURE_COUNT);
      else if(key == "weights")
         hasWeights = ParseDoubleList(value, ModelWeights, MODEL_FEATURE_COUNT);
   }

   FileClose(handle);

   ModelGateEnabled = (enabled && hasMean && hasScale && hasWeights);

   if(!ModelGateEnabled && enabled)
      ModelReason = "Model file is incomplete. Recording only.";
}

bool ParseDoubleList(string value, double &target[], int expectedCount)
{
   string parts[];
   int count = StringSplit(value, ',', parts);

   if(count < expectedCount)
      return false;

   for(int i = 0; i < expectedCount; i++)
      target[i] = StringToDouble(parts[i]);

   return true;
}

bool AiAllowsEntry(int spread, double &score)
{
   double features[MODEL_FEATURE_COUNT];
   GetFeatureVector(features, spread);
   score = ScoreModel(features);
   LastModelScore = score;

   if(!AiFilterActive() || !ModelGateEnabled)
      return true;

   if(score >= ModelThreshold)
      return true;

   string message = "AI blocked entry. Score " + DoubleToString(score, 3) +
                    " < " + DoubleToString(ModelThreshold, 3) + ".";
   SetStatus(message);

   if(LastModelBlockLog == 0 || TimeCurrent() - LastModelBlockLog >= 60)
   {
      LastModelBlockLog = TimeCurrent();
      AppendEvent("AI_BLOCK", spread, 0.0, message);
   }

   return false;
}

double ScoreModel(double &features[])
{
   if(!ModelGateEnabled)
      return 0.5;

   double z = ModelBias;

   for(int i = 0; i < MODEL_FEATURE_COUNT; i++)
   {
      double scale = ModelScale[i];
      if(scale <= 0.0)
         scale = 1.0;

      z += ModelWeights[i] * ((features[i] - ModelMean[i]) / scale);
   }

   if(z > 30.0)
      return 1.0;

   if(z < -30.0)
      return 0.0;

   return 1.0 / (1.0 + MathExp(-z));
}

void GetFeatureVector(double &features[], int spread)
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   RefreshFeatureCache(false);

   features[0] = (double)spread;
   features[1] = (double)now.hour;
   features[2] = (double)now.day_of_week;
   features[3] = CachedAtrPoints;
   features[4] = CachedRangePoints;
   features[5] = CachedMaDeltaPoints;
   features[6] = CachedRsi14;
   features[7] = (double)ActiveZoneHeight();
   features[8] = ActiveMultiplier();
   features[9] = (double)ActiveMaxTurns();
}

void RefreshFeatureCache(bool forceRefresh)
{
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);

   if(!forceRefresh && FeatureCacheReady && currentBarTime == FeatureCacheBarTime)
      return;

   FeatureCacheBarTime = currentBarTime;
   CachedAtrPoints = IndicatorAtrPoints();
   CachedRangePoints = LastClosedRangePoints();
   CachedMaDeltaPoints = IndicatorMaDeltaPoints();
   CachedRsi14 = IndicatorRsi();
   FeatureCacheReady = true;
}

bool CopyClosedBufferValue(int handle, double &value)
{
   if(handle == INVALID_HANDLE)
      return false;

   double buffer[];
   ArraySetAsSeries(buffer, true);
   ResetLastError();

   int copied = CopyBuffer(handle, 0, 1, 1, buffer);
   if(copied != 1)
      return false;

   value = buffer[0];
   return true;
}

//--- Stops must be sized from the timeframe the EA actually trades on.
//--- PERIOD_CURRENT gave a daily ATR when the EA sat on an H1/D1 chart.
double EntryTimeframeAtrPoints()
{
   double atr = 0.0;

   if(CopyClosedBufferValue(AtrEntryHandle, atr) && atr > 0.0 && _Point > 0.0)
      return atr / _Point;

   RefreshFeatureCache(false);
   return CachedAtrPoints;
}

double IndicatorAtrPoints()
{
   double atr = 0.0;

   if(CopyClosedBufferValue(AtrHandle, atr) && atr > 0.0 && _Point > 0.0)
      return atr / _Point;

   return CalculateAtrPoints(14);
}

double IndicatorMaDeltaPoints()
{
   double fastMa = 0.0;
   double slowMa = 0.0;

   if(CopyClosedBufferValue(FastMaHandle, fastMa) &&
      CopyClosedBufferValue(SlowMaHandle, slowMa) &&
      fastMa > 0.0 &&
      slowMa > 0.0 &&
      _Point > 0.0)
      return (fastMa - slowMa) / _Point;

   return CalculateMaDeltaPoints(10, 30);
}

double IndicatorRsi()
{
   double rsi = 50.0;

   if(CopyClosedBufferValue(RsiHandle, rsi) && rsi >= 0.0 && rsi <= 100.0)
      return rsi;

   return CalculateRsi(14);
}

double LastClosedRangePoints()
{
   double high = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double low = iLow(_Symbol, PERIOD_CURRENT, 1);

   if(high <= 0.0 || low <= 0.0 || _Point <= 0.0)
      return 0.0;

   return (high - low) / _Point;
}

double CalculateAtrPoints(int period)
{
   if(period <= 0 || _Point <= 0.0)
      return 0.0;

   double total = 0.0;
   int counted = 0;

   for(int shift = 1; shift <= period; shift++)
   {
      double high = iHigh(_Symbol, PERIOD_CURRENT, shift);
      double low = iLow(_Symbol, PERIOD_CURRENT, shift);
      double previousClose = iClose(_Symbol, PERIOD_CURRENT, shift + 1);

      if(high <= 0.0 || low <= 0.0 || previousClose <= 0.0)
         continue;

      double trueRange = MathMax(high - low, MathMax(MathAbs(high - previousClose), MathAbs(low - previousClose)));
      total += trueRange;
      counted++;
   }

   if(counted == 0)
      return 0.0;

   return (total / counted) / _Point;
}

double CalculateMaDeltaPoints(int fastPeriod, int slowPeriod)
{
   double fastMa = SimpleMa(fastPeriod);
   double slowMa = SimpleMa(slowPeriod);

   if(fastMa <= 0.0 || slowMa <= 0.0 || _Point <= 0.0)
      return 0.0;

   return (fastMa - slowMa) / _Point;
}

double SimpleMa(int period)
{
   if(period <= 0)
      return 0.0;

   double total = 0.0;
   int counted = 0;

   for(int shift = 1; shift <= period; shift++)
   {
      double closePrice = iClose(_Symbol, PERIOD_CURRENT, shift);
      if(closePrice <= 0.0)
         continue;

      total += closePrice;
      counted++;
   }

   if(counted == 0)
      return 0.0;

   return total / counted;
}

double SimpleMaOnTimeframe(ENUM_TIMEFRAMES timeframe, int period)
{
   if(period <= 0)
      return 0.0;

   double total = 0.0;
   int counted = 0;

   for(int shift = 1; shift <= period; shift++)
   {
      double closePrice = iClose(_Symbol, timeframe, shift);
      if(closePrice <= 0.0)
         continue;

      total += closePrice;
      counted++;
   }

   if(counted == 0)
      return 0.0;

   return total / counted;
}

double CalculateRsiOnTimeframe(ENUM_TIMEFRAMES timeframe, int period)
{
   if(period <= 0)
      return 50.0;

   double gains = 0.0;
   double losses = 0.0;
   int counted = 0;

   for(int shift = 1; shift <= period; shift++)
   {
      double closeNow = iClose(_Symbol, timeframe, shift);
      double closePrevious = iClose(_Symbol, timeframe, shift + 1);

      if(closeNow <= 0.0 || closePrevious <= 0.0)
         continue;

      double change = closeNow - closePrevious;
      if(change >= 0.0)
         gains += change;
      else
         losses += MathAbs(change);

      counted++;
   }

   if(counted == 0)
      return 50.0;

   double averageGain = gains / counted;
   double averageLoss = losses / counted;

   if(averageLoss <= 0.0)
      return 100.0;

   double rs = averageGain / averageLoss;
   return 100.0 - (100.0 / (1.0 + rs));
}

double CalculateRsi(int period)
{
   if(period <= 0)
      return 50.0;

   double gains = 0.0;
   double losses = 0.0;
   int counted = 0;

   for(int shift = 1; shift <= period; shift++)
   {
      double closeNow = iClose(_Symbol, PERIOD_CURRENT, shift);
      double closePrevious = iClose(_Symbol, PERIOD_CURRENT, shift + 1);

      if(closeNow <= 0.0 || closePrevious <= 0.0)
         continue;

      double change = closeNow - closePrevious;
      if(change >= 0.0)
         gains += change;
      else
         losses += MathAbs(change);

      counted++;
   }

   if(counted == 0)
      return 50.0;

   double averageGain = gains / counted;
   double averageLoss = losses / counted;

   if(averageLoss <= 0.0)
      return 100.0;

   double rs = averageGain / averageLoss;
   return 100.0 - (100.0 / (1.0 + rs));
}

void StartCycle(double bid, double ask, int spread, double modelScore)
{
   CycleId = IntegerToString((long)TimeCurrent()) + "_" + _Symbol + "_" + IntegerToString(InpMagic);
   CycleStartedAt = TimeCurrent();
   CycleStartBid = bid;
   CycleStartAsk = ask;
   CycleStartSpread = spread;
   CycleModelScore = modelScore;
   CycleWorstProfit = 0.0;
   CyclePeakProfit = 0.0;
   MaxTurnsLogged = false;
   GetFeatureVector(CycleFeatures, spread);
   AppendEvent("CYCLE_START", spread, 0.0, "model_score=" + DoubleToString(modelScore, 4));
}

void FinishCycle(string exitReason, int spread, double totalProfit)
{
   if(CycleId == "")
   {
      AppendEvent("CYCLE_END_NO_ID", spread, totalProfit, exitReason);
      return;
   }

   int durationSeconds = (int)(TimeCurrent() - CycleStartedAt);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   WriteCycleRow(exitReason, durationSeconds, spread, bid, ask, totalProfit);
   AppendEvent("CYCLE_END", spread, totalProfit, exitReason);
}

void AppendEvent(string eventName, int spread, double totalProfit, string detail)
{
   if(!InpEnableCsvLogging)
      return;

   int handle = FileOpen(InpEventLogFile,
                         FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_ANSI,
                         ',');

   if(handle == INVALID_HANDLE)
      return;

   bool writeHeader = (FileSize(handle) == 0);
   FileSeek(handle, 0, SEEK_END);

   if(writeHeader)
      FileWrite(handle, "timestamp", "symbol", "event", "message", "spread", "bid", "ask",
                "turns", "total_profit", "model_score", "model_threshold", "cycle_id");

   FileWrite(handle,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             _Symbol,
             eventName,
             detail,
             spread,
             DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits),
             DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), _Digits),
             CurrentTurns,
             DoubleToString(totalProfit, 2),
             DoubleToString(LastModelScore, 4),
             DoubleToString(ModelThreshold, 4),
             CycleId);

   FileClose(handle);
}

void WriteCycleRow(string exitReason, int durationSeconds, int exitSpread, double exitBid, double exitAsk, double totalProfit)
{
   if(!InpEnableCsvLogging)
      return;

   int handle = FileOpen(InpCycleLogFile,
                         FILE_READ | FILE_WRITE | FILE_CSV | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_ANSI,
                         ',');

   if(handle == INVALID_HANDLE)
      return;

   bool writeHeader = (FileSize(handle) == 0);
   FileSeek(handle, 0, SEEK_END);

   if(writeHeader)
      FileWrite(handle,
                "timestamp", "cycle_id", "symbol", "exit_reason", "start_time", "end_time",
                "duration_sec", "entry_bid", "entry_ask", "exit_bid", "exit_ask",
                "start_spread", "exit_spread", "initial_lot", "zone_height", "multiplier",
                "target_usd", "max_turns", "turns_used", "model_score", "model_threshold",
                "spread", "hour", "day_of_week", "atr_points", "last_range_points",
                "ma_delta_points", "rsi14", "feature_zone_height", "feature_multiplier",
                "feature_max_turns", "exit_profit", "max_floating_loss", "win");

   int winFlag = (totalProfit >= 0.0 ? 1 : 0);

   FileWrite(handle,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             CycleId,
             _Symbol,
             exitReason,
             TimeToString(CycleStartedAt, TIME_DATE | TIME_SECONDS),
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             durationSeconds,
             DoubleToString(CycleStartBid, _Digits),
             DoubleToString(CycleStartAsk, _Digits),
             DoubleToString(exitBid, _Digits),
             DoubleToString(exitAsk, _Digits),
             CycleStartSpread,
             exitSpread,
             DoubleToString(ActiveInitialLot(), 2),
             ActiveZoneHeight(),
             DoubleToString(ActiveMultiplier(), 2),
             DoubleToString(ActiveTargetUSD(), 2),
             ActiveMaxTurns(),
             CurrentTurns,
             DoubleToString(CycleModelScore, 4),
             DoubleToString(ModelThreshold, 4),
             DoubleToString(CycleFeatures[0], 4),
             DoubleToString(CycleFeatures[1], 4),
             DoubleToString(CycleFeatures[2], 4),
             DoubleToString(CycleFeatures[3], 4),
             DoubleToString(CycleFeatures[4], 4),
             DoubleToString(CycleFeatures[5], 4),
             DoubleToString(CycleFeatures[6], 4),
             DoubleToString(CycleFeatures[7], 4),
             DoubleToString(CycleFeatures[8], 4),
             DoubleToString(CycleFeatures[9], 4),
             DoubleToString(totalProfit, 2),
             DoubleToString(CycleWorstProfit, 2),
             winFlag);

   FileClose(handle);
}

void ReadDashboardControl(bool forceRead)
{
   if(!DashboardControlActive())
   {
      DashboardEnabled = true;
      DashboardCloseAll = false;
      return;
   }

   int pollSeconds = InpControlPollSeconds;
   if(pollSeconds < 1)
      pollSeconds = 1;

   if(!forceRead && LastControlRead != 0 && TimeCurrent() - LastControlRead < pollSeconds)
      return;

   LastControlRead = TimeCurrent();

   int handle = FileOpen(InpControlFile,
                         FILE_READ | FILE_TXT | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_ANSI);

   if(handle == INVALID_HANDLE)
   {
      DashboardEnabled = false;
      DashboardCloseAll = false;
      return;
   }

   DashboardEnabled = false;
   DashboardCloseAll = false;
   DashboardInitialLot = 0.0;
   DashboardZoneHeight = 0;
   DashboardMultiplier = 0.0;
   DashboardTargetUSD = 0.0;
   DashboardQuickTargetUSD = -1.0;
   DashboardMaxLossUSD = -1.0;
   DashboardAllowRecovery = -1;
   DashboardTakeProfitPoints = -1;
   DashboardStopLossPoints = -1;
   DashboardMaxLot = -1.0;
   DashboardMaxSameSide = -1;
   DashboardMinSameSideDistance = -1;
   DashboardMaxTurns = 0;
   DashboardMaxSpread = 0;

   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      int equalsAt = StringFind(line, "=");

      if(equalsAt <= 0)
         continue;

      string key = StringSubstr(line, 0, equalsAt);
      string value = StringSubstr(line, equalsAt + 1);

      if(key == "enabled")
         DashboardEnabled = IsTrueValue(value);
      else if(key == "close_all")
         DashboardCloseAll = IsTrueValue(value);
      else if(key == "initial_lot")
         DashboardInitialLot = StringToDouble(value);
      else if(key == "zone_height")
         DashboardZoneHeight = (int)StringToInteger(value);
      else if(key == "multiplier")
         DashboardMultiplier = StringToDouble(value);
      else if(key == "target_usd")
         DashboardTargetUSD = StringToDouble(value);
      else if(key == "quick_target_usd")
         DashboardQuickTargetUSD = StringToDouble(value);
      else if(key == "max_loss_usd")
         DashboardMaxLossUSD = StringToDouble(value);
      else if(key == "allow_recovery")
         DashboardAllowRecovery = (int)StringToInteger(value);
      else if(key == "take_profit_points")
         DashboardTakeProfitPoints = (int)StringToInteger(value);
      else if(key == "stop_loss_points")
         DashboardStopLossPoints = (int)StringToInteger(value);
      else if(key == "max_lot")
         DashboardMaxLot = StringToDouble(value);
      else if(key == "max_same_side")
         DashboardMaxSameSide = (int)StringToInteger(value);
      else if(key == "min_same_side_distance")
         DashboardMinSameSideDistance = (int)StringToInteger(value);
      else if(key == "max_turns")
         DashboardMaxTurns = (int)StringToInteger(value);
      else if(key == "max_spread")
         DashboardMaxSpread = (int)StringToInteger(value);
   }

   FileClose(handle);
}

void WriteDashboardStatus(int spread, bool hasPosition, double totalProfit, bool forceWrite=false)
{
   if(!DashboardControlActive())
      return;

   int writeSeconds = InpStatusWriteSeconds;
   if(writeSeconds < 1)
      writeSeconds = 1;

   if(!forceWrite && LastStatusWrite != 0 && TimeCurrent() - LastStatusWrite < writeSeconds)
      return;

   LastStatusWrite = TimeCurrent();

   int handle = FileOpen(InpStatusFile,
                         FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_ANSI);

   if(handle == INVALID_HANDLE)
      return;

   FileWriteString(handle, "ea_message=" + LastStatus + "\n");
   FileWriteString(handle, "app_version=" + EA_APP_VERSION + "\n");
   FileWriteString(handle, "ea_version=" + EA_BUILD_VERSION + "\n");
   FileWriteString(handle, "ea_build_number=" + IntegerToString(EA_BUILD_NUMBER) + "\n");
   FileWriteString(handle, "symbol=" + _Symbol + "\n");
   FileWriteString(handle, "event_source=" + LastEventSource + "\n");
   FileWriteString(handle, "dashboard_enabled=" + BoolFlag(DashboardEnabled) + "\n");
   FileWriteString(handle, "close_all=" + BoolFlag(DashboardCloseAll) + "\n");
   FileWriteString(handle, "has_position=" + BoolFlag(hasPosition) + "\n");
   FileWriteString(handle, "spread=" + IntegerToString(spread) + "\n");
   FileWriteString(handle, "max_spread=" + IntegerToString(ActiveMaxSpread()) + "\n");
   FileWriteString(handle, "turns=" + IntegerToString(CurrentTurns) + "\n");
   FileWriteString(handle, "total_profit=" + DoubleToString(totalProfit, 2) + "\n");
   FileWriteString(handle, "quick_target_usd=" + DoubleToString(EffectiveQuickTargetUSD(), 2) + "\n");
   FileWriteString(handle, "max_loss_usd=" + DoubleToString(EffectiveMaxFloatingLossUSD(), 2) + "\n");
   FileWriteString(handle, "requested_quick_target_usd=" + DoubleToString(ActiveQuickTargetUSD(), 2) + "\n");
   FileWriteString(handle, "effective_target_points=" + IntegerToString(EffectiveTargetPoints()) + "\n");
   FileWriteString(handle, "entry_atr_points=" + DoubleToString(EntryTimeframeAtrPoints(), 1) + "\n");
   FileWriteString(handle, "allow_recovery=" + BoolFlag(ActiveAllowRecovery()) + "\n");
   FileWriteString(handle, "take_profit_points=" + IntegerToString(ActiveTakeProfitPoints()) + "\n");
   FileWriteString(handle, "stop_loss_points=" + IntegerToString(ActiveStopLossPoints()) + "\n");
   FileWriteString(handle, "max_lot=" + DoubleToString(ActiveMaxLot(), 2) + "\n");
   FileWriteString(handle, "max_same_side=" + IntegerToString(ActiveMaxSameSidePositions()) + "\n");
   FileWriteString(handle, "min_same_side_distance=" + IntegerToString(ActiveMinSameSideDistancePoints()) + "\n");
   FileWriteString(handle, "upper_level=" + DoubleToString(UpperLevel, _Digits) + "\n");
   FileWriteString(handle, "lower_level=" + DoubleToString(LowerLevel, _Digits) + "\n");
   FileWriteString(handle, "cycle_id=" + CycleId + "\n");
   FileWriteString(handle, "cycle_worst_profit=" + DoubleToString(CycleWorstProfit, 2) + "\n");
   FileWriteString(handle, "cycle_peak_profit=" + DoubleToString(CyclePeakProfit, 2) + "\n");
   FileWriteString(handle, "profit_lock_trigger=" + DoubleToString(InpUseProfitLock ? ScaledMoney(InpProfitLockTriggerUSD) : 0.0, 2) + "\n");
   FileWriteString(handle, "profit_lock_giveback=" + DoubleToString(InpUseProfitLock ? ScaledMoney(InpProfitLockGiveBackUSD) : 0.0, 2) + "\n");
   FileWriteString(handle, "ultra_open_mode=" + BoolFlag(InpUltraOpenMode) + "\n");
   FileWriteString(handle, "account_currency=" + AccountMoneyLabel + "\n");
   FileWriteString(handle, "money_scale=" + DoubleToString(AccountMoneyScale, 2) + "\n");
   FileWriteString(handle, "resolved_take_profit_points=" + IntegerToString(ResolveTakeProfitPoints()) + "\n");
   FileWriteString(handle, "resolved_stop_loss_points=" + IntegerToString(ResolveStopLossPoints()) + "\n");
   FileWriteString(handle, "atr_points=" + DoubleToString(CachedAtrPoints, 1) + "\n");
   FileWriteString(handle, "entry_trend_signal=" + EntryTrendLabel() + "\n");
   FileWriteString(handle, "entry_trend_move_points=" + DoubleToString(LastEntryTrendMovePoints, 1) + "\n");
   FileWriteString(handle, "entry_trend_body_points=" + DoubleToString(LastEntryTrendBodyPoints, 1) + "\n");
   FileWriteString(handle, "entry_trend_ma_delta_points=" + DoubleToString(LastEntryTrendMaDeltaPoints, 1) + "\n");
   FileWriteString(handle, "entry_trend_rsi=" + DoubleToString(LastEntryTrendRsi, 1) + "\n");
   FileWriteString(handle, "entry_trend_reason=" + LastEntryTrendReason + "\n");
   FileWriteString(handle, "scalp_closed_trades=" + IntegerToString(ScalpClosedTrades) + "\n");
   FileWriteString(handle, "scalp_max_closed_trades=" + IntegerToString(InpScalpMaxClosedTrades) + "\n");
   FileWriteString(handle, "consecutive_losses=" + IntegerToString(ConsecutiveLosses) + "\n");
   FileWriteString(handle, "last_closed_profit=" + DoubleToString(LastClosedProfit, 2) + "\n");
   FileWriteString(handle, "last_loss_side=" + SideLabel(LastLossSide) + "\n");
   FileWriteString(handle, "scalp_risk_reason=" + LastScalpRiskReason + "\n");
   FileWriteString(handle, "model_file_found=" + BoolFlag(ModelFileFound) + "\n");
   FileWriteString(handle, "model_enabled=" + BoolFlag(ModelGateEnabled) + "\n");
   FileWriteString(handle, "model_score=" + DoubleToString(LastModelScore, 4) + "\n");
   FileWriteString(handle, "model_threshold=" + DoubleToString(ModelThreshold, 4) + "\n");
   FileWriteString(handle, "model_trained_rows=" + IntegerToString(ModelTrainedRows) + "\n");
   FileWriteString(handle, "model_reason=" + ModelReason + "\n");
   FileWriteString(handle, "updated_at=" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\n");

   FileClose(handle);
}

void AcknowledgeCloseAllCommand()
{
   if(!DashboardControlActive())
      return;

   int handle = FileOpen(InpControlFile,
                         FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_ANSI);

   if(handle == INVALID_HANDLE)
   {
      SetStatus("Close-all handled, but EA could not clear the control file.");
      return;
   }

   FileWriteString(handle, "enabled=0\n");
   FileWriteString(handle, "close_all=0\n");
   FileWriteString(handle, "initial_lot=" + DoubleToString(ActiveInitialLot(), 2) + "\n");
   FileWriteString(handle, "zone_height=" + IntegerToString(ActiveZoneHeight()) + "\n");
   FileWriteString(handle, "multiplier=" + DoubleToString(ActiveMultiplier(), 2) + "\n");
   FileWriteString(handle, "target_usd=" + DoubleToString(ActiveTargetUSD(), 2) + "\n");
   FileWriteString(handle, "quick_target_usd=" + DoubleToString(ActiveQuickTargetUSD(), 2) + "\n");
   FileWriteString(handle, "max_loss_usd=" + DoubleToString(ActiveMaxFloatingLossUSD(), 2) + "\n");
   FileWriteString(handle, "allow_recovery=" + BoolFlag(ActiveAllowRecovery()) + "\n");
   FileWriteString(handle, "take_profit_points=" + IntegerToString(ActiveTakeProfitPoints()) + "\n");
   FileWriteString(handle, "stop_loss_points=" + IntegerToString(ActiveStopLossPoints()) + "\n");
   FileWriteString(handle, "max_lot=" + DoubleToString(ActiveMaxLot(), 2) + "\n");
   FileWriteString(handle, "max_same_side=" + IntegerToString(ActiveMaxSameSidePositions()) + "\n");
   FileWriteString(handle, "min_same_side_distance=" + IntegerToString(ActiveMinSameSideDistancePoints()) + "\n");
   FileWriteString(handle, "max_turns=" + IntegerToString(ActiveMaxTurns()) + "\n");
   FileWriteString(handle, "max_spread=" + IntegerToString(ActiveMaxSpread()) + "\n");
   FileWriteString(handle, "updated_by=mt5\n");
   FileWriteString(handle, "ack=close_all\n");
   FileWriteString(handle, "ack_at=" + TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS) + "\n");
   FileClose(handle);

   DashboardCloseAll = false;
   DashboardEnabled = false;
}

bool IsTrueValue(string value)
{
   return(value == "1" || value == "true" || value == "TRUE" || value == "True");
}

string BoolFlag(bool value)
{
   return(value ? "1" : "0");
}

double ActiveInitialLot()
{
   return(DashboardInitialLot > 0.0 ? DashboardInitialLot : InitialLot);
}

int ActiveZoneHeight()
{
   return(DashboardZoneHeight > 0 ? DashboardZoneHeight : ZoneHeight);
}

double ActiveMultiplier()
{
   return(DashboardMultiplier > 0.0 ? DashboardMultiplier : Multiplier);
}

//--- Money targets are entered in USD and scaled into account currency,
//--- so 0.25 means a real 0.25 USD on both standard and cent accounts.
double ActiveTargetUSD()
{
   return(ScaledMoney(DashboardTargetUSD > 0.0 ? DashboardTargetUSD : TargetUSD));
}

double ActiveQuickTargetUSD()
{
   return(ScaledMoney(DashboardQuickTargetUSD >= 0.0 ? DashboardQuickTargetUSD : InpQuickBasketProfitUSD));
}

double ActiveMaxFloatingLossUSD()
{
   // >= 0 so a dashboard value of 0 really does disable the cap.
   return(ScaledMoney(DashboardMaxLossUSD >= 0.0 ? DashboardMaxLossUSD : InpMaxFloatingLossUSD));
}

bool ActiveAllowRecovery()
{
   return(DashboardAllowRecovery >= 0 ? DashboardAllowRecovery == 1 : InpAllowRecovery);
}

int ActiveTakeProfitPoints()
{
   return(DashboardTakeProfitPoints >= 0 ? DashboardTakeProfitPoints : InpTakeProfitPoints);
}

int ActiveStopLossPoints()
{
   return(DashboardStopLossPoints >= 0 ? DashboardStopLossPoints : InpStopLossPoints);
}

double ActiveMaxLot()
{
   return(DashboardMaxLot >= 0.0 ? DashboardMaxLot : InpMaxRecoveryLot);
}

int ActiveMaxSameSidePositions()
{
   return(DashboardMaxSameSide >= 0 ? DashboardMaxSameSide : InpMaxSameSidePositions);
}

int ActiveMinSameSideDistancePoints()
{
   return(DashboardMinSameSideDistance >= 0 ? DashboardMinSameSideDistance : InpMinSameSideDistancePoints);
}

int ActiveMaxTurns()
{
   return(DashboardMaxTurns > 0 ? DashboardMaxTurns : MaxTurns);
}

int ActiveMaxSpread()
{
   return(DashboardMaxSpread > 0 ? DashboardMaxSpread : InpMaxSpread);
}

double NormalizeVolume(double volume)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;

   if(minLot > 0.0 && volume < minLot)
      volume = minLot;

   if(maxLot > 0.0 && volume > maxLot)
      volume = maxLot;

   volume = MathFloor((volume / step) + 0.5) * step;

   if(minLot > 0.0 && volume < minLot)
      volume = minLot;

   return NormalizeDouble(volume, VolumeDigits(step));
}

int VolumeDigits(double step)
{
   string text = DoubleToString(step, 8);
   int dotAt = StringFind(text, ".");

   if(dotAt < 0)
      return 0;

   while(StringLen(text) > dotAt + 1 && StringSubstr(text, StringLen(text) - 1, 1) == "0")
      text = StringSubstr(text, 0, StringLen(text) - 1);

   return StringLen(text) - dotAt - 1;
}

bool TradingAllowed()
{
   bool terminalAllowed = (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
   bool eaAllowed       = (bool)MQLInfoInteger(MQL_TRADE_ALLOWED);
   bool accountAllowed  = (bool)AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
   bool expertAllowed   = (bool)AccountInfoInteger(ACCOUNT_TRADE_EXPERT);
   long symbolMode      = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

   return(terminalAllowed &&
          eaAllowed &&
          accountAllowed &&
          expertAllowed &&
          symbolMode == SYMBOL_TRADE_MODE_FULL);
}

bool TradeSucceeded()
{
   uint retcode = trade.ResultRetcode();
   return(retcode == TRADE_RETCODE_DONE ||
          retcode == TRADE_RETCODE_DONE_PARTIAL ||
          retcode == TRADE_RETCODE_PLACED);
}

void LogTradeFailure(string action)
{
   string message = action + " failed. Retcode: " +
                    IntegerToString((int)trade.ResultRetcode()) + " " +
                    trade.ResultRetcodeDescription() +
                    ". LastError: " + IntegerToString(GetLastError());
   SetStatus(message);
   AppendEvent("TRADE_FAILURE", (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD), CurrentManagedProfit(), message);
   ResetLastError();
}

void SetStatus(string status)
{
   if(status != LastStatus)
   {
      LastStatus = status;
      Print("RECOVERY SHIELD: ", LastStatus);
   }
}

void DrawDashboard(int spread) {
   if(LastDashboardDraw != 0 && TimeCurrent() - LastDashboardDraw < 1)
      return;

   LastDashboardDraw = TimeCurrent();

   string status = (spread <= ActiveMaxSpread()) ? "SAFE" : "TOXIC SPREAD";
   string dashboard = DashboardControlActive() ? (DashboardEnabled ? "RUNNING" : "PAUSED") : "LOCAL INPUTS";
   string modelStatus = AiFilterActive() ? (ModelGateEnabled ? "ACTIVE" : "RECORDING") : "OFF";

   Comment("--- RECOVERY SHIELD ---\n",
           "Version: ", EA_BUILD_VERSION, " | Entry: ", InpUltraOpenMode ? "ULTRA OPEN" : "STRICT", "\n",
           "Current Spread: ", spread, "\n",
           "Max Allowed: ", ActiveMaxSpread(), "\n",
           "Status: ", status, "\n",
           "Dashboard: ", dashboard, "\n",
           "Target: ", DoubleToString(EffectiveQuickTargetUSD(), 2),
           " (", EffectiveTargetPoints(), "pts) | Loss cap: ",
           DoubleToString(EffectiveMaxFloatingLossUSD(), 2), "\n",
           "Peak: ", DoubleToString(CyclePeakProfit, 2),
           " | Entry ATR: ", DoubleToString(EntryTimeframeAtrPoints(), 0), "\n",
           "Account: ", AccountMoneyLabel, " x", DoubleToString(AccountMoneyScale, 0),
           " | ATR: ", DoubleToString(CachedAtrPoints, 0), "\n",
           "Recovery: ", ActiveAllowRecovery() ? "ON" : "OFF",
           " | TP/SL: ", ResolveTakeProfitPoints(), "/", ResolveStopLossPoints(), "\n",
           "Entry Trend: ", EntryTrendLabel(), " | ", LastEntryTrendReason, "\n",
           "Scalps: ", ScalpClosedTrades, "/", InpScalpMaxClosedTrades,
           " | Loss Streak: ", ConsecutiveLosses, "\n",
           "Max Lot: ", DoubleToString(ActiveMaxLot(), 2), " | Same Side Max: ", ActiveMaxSameSidePositions(), "\n",
           "AI Filter: ", modelStatus, " | Score: ", DoubleToString(LastModelScore, 3), "\n",
           "EA Message: ", LastStatus, "\n",
           "Turns: ", CurrentTurns);
}
