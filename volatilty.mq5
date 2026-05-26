//+------------------------------------------------------------------+
//|                                     RecoveryZone_Shielded_V1.mq5 |
//|                                  Copyright 2026, Gemini Academic |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

#define MODEL_FEATURE_COUNT 10

//--- Input Parameters
input group "Recovery Settings"
input double InitialLot   = 0.01;      // Starting Lot Size
input int    ZoneHeight   = 500;       // Distance between Buy and Sell (Points)
input double Multiplier   = 1.6;       // Recovery Multiplier (e.g. 1.6x)
input double TargetUSD    = 1.0;       // Close all when Net Profit reaches this $ amount
input int    MaxTurns     = 10;        // Max number of recovery trades

input group "The Shields (Safety Filters)"
input int    InpMaxSpread    = 25;     // Block new cycles if spread > 25
input int    InpMaxCycleTime = 3600;   // Kill the whole cycle if stuck for 1hr (Seconds)
input int    InpMagic        = 999999;

input group "Django Dashboard Control"
input bool   InpUseDashboardControl = true;
input string InpControlFile         = "recovery_shield_control.txt";
input string InpStatusFile          = "recovery_shield_status.txt";

input group "Logging and AI Filter"
input bool   InpEnableCsvLogging    = true;
input string InpEventLogFile        = "recovery_shield_events.csv";
input string InpCycleLogFile        = "recovery_shield_cycles.csv";
input bool   InpUseAiFilter         = true;
input string InpModelFile           = "recovery_shield_model.txt";
input double InpDefaultModelThreshold = 0.55;

input group "Performance"
input int    InpControlPollSeconds  = 1;        // Read dashboard commands at most once per N seconds
input int    InpStatusWriteSeconds  = 2;        // Write dashboard status at most once per N seconds
input int    InpTradeDeviationPoints = 20;      // Max price deviation used by CTrade

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
int            DashboardMaxTurns = 0;
int            DashboardMaxSpread = 0;
datetime       LastStatusWrite = 0;
datetime       LastControlRead = 0;
datetime       LastDashboardDraw = 0;
string         LastEventSource = "init";
string         CycleId = "";
datetime       CycleStartedAt = 0;
double         CycleStartBid = 0.0;
double         CycleStartAsk = 0.0;
int            CycleStartSpread = 0;
double         CycleFeatures[MODEL_FEATURE_COUNT];
double         CycleModelScore = 0.0;
double         CycleWorstProfit = 0.0;
bool           MaxTurnsLogged = false;
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
int            FastMaHandle = INVALID_HANDLE;
int            SlowMaHandle = INVALID_HANDLE;
int            RsiHandle = INVALID_HANDLE;
bool           FeatureCacheReady = false;
datetime       FeatureCacheBarTime = 0;
double         CachedAtrPoints = 0.0;
double         CachedRangePoints = 0.0;
double         CachedMaDeltaPoints = 0.0;
double         CachedRsi14 = 50.0;

int OnInit() {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpTradeDeviationPoints);
   AtrHandle = iATR(_Symbol, PERIOD_CURRENT, 14);
   FastMaHandle = iMA(_Symbol, PERIOD_CURRENT, 10, 0, MODE_SMA, PRICE_CLOSE);
   SlowMaHandle = iMA(_Symbol, PERIOD_CURRENT, 30, 0, MODE_SMA, PRICE_CLOSE);
   RsiHandle = iRSI(_Symbol, PERIOD_CURRENT, 14, PRICE_CLOSE);
   InitializeModelDefaults();
   ReadDashboardControl(true);
   ReadAiModel(true);
   EventSetTimer(1);
   SetStatus("EA initialized on " + _Symbol + ". Waiting for dashboard command.");
   AppendEvent("EA_INIT", 0, 0.0, "initialized");
   Comment("--- RECOVERY SHIELD ---\n",
           "Status: ", LastStatus, "\n",
           "If no trade opens, check the Experts tab.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ReleaseIndicator(AtrHandle);
   ReleaseIndicator(FastMaHandle);
   ReleaseIndicator(SlowMaHandle);
   ReleaseIndicator(RsiHandle);
   Comment("");
}

void OnTick()
{
   RunEngine("tick");
}

void OnTimer()
{
   RunEngine("timer");
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
   double totalProfit = 0;
   ENUM_POSITION_TYPE lastType = (ENUM_POSITION_TYPE)-1;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == InpMagic)
      {
         hasPosition = true;
         totalProfit += m_position.Profit() + m_position.Commission() + m_position.Swap();
         lastType = m_position.PositionType();
      }
   }

   if(hasPosition && CycleId != "" && totalProfit < CycleWorstProfit)
      CycleWorstProfit = totalProfit;

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
      
      if(totalProfit >= ActiveTargetUSD() || timeOut) {
         if(timeOut) Print("SHIELD: Cycle timed out. Closing to prevent 24hr trap.");
         FinishCycle(timeOut ? "timeout" : "target", spread, totalProfit);
         CloseAll();
         ResetEA();
         WriteDashboardStatus(spread, false, 0.0, true);
         return;
      }
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

      double modelScore = 0.0;
      if(!AiAllowsEntry(spread, modelScore))
      {
         DrawDashboard(spread);
         WriteDashboardStatus(spread, hasPosition, totalProfit);
         return;
      }

      double entryLot = NormalizeVolume(ActiveInitialLot());
      if(trade.Buy(entryLot, _Symbol, ask, 0, 0))
      {
         if(TradeSucceeded())
         {
            UpperLevel = ask;
            LowerLevel = ask - (ActiveZoneHeight() * _Point);
            CurrentTurns = 1;
            CycleStartTime = TimeCurrent();
            StartCycle(bid, ask, spread, modelScore);
            SetStatus("Initial BUY opened.");
            AppendEvent("TRADE_BUY", spread, CurrentManagedProfit(), "initial_lot=" + DoubleToString(entryLot, 2));
         }
         else
         {
            LogTradeFailure("Initial BUY");
         }
      }
      else
      {
         LogTradeFailure("Initial BUY");
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
      if(bid <= LowerLevel && lastType == POSITION_TYPE_BUY)
      {
         double nextLot = NormalizeVolume(ActiveInitialLot() * MathPow(ActiveMultiplier(), CurrentTurns));
         if(trade.Sell(nextLot, _Symbol, bid, 0, 0) && TradeSucceeded())
         {
            CurrentTurns++;
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
         double nextLot = NormalizeVolume(ActiveInitialLot() * MathPow(ActiveMultiplier(), CurrentTurns));
         if(trade.Buy(nextLot, _Symbol, ask, 0, 0) && TradeSucceeded())
         {
            CurrentTurns++;
            SetStatus("Recovery BUY opened.");
            AppendEvent("TRADE_BUY", spread, totalProfit, "recovery_lot=" + DoubleToString(nextLot, 2));
         }
         else
         {
            LogTradeFailure("Recovery BUY");
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
   if(!InpUseAiFilter)
   {
      ModelGateEnabled = false;
      ModelReason = "AI filter disabled in EA inputs.";
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

   if(!InpUseAiFilter || !ModelGateEnabled)
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
   if(!InpUseDashboardControl)
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
      else if(key == "max_turns")
         DashboardMaxTurns = (int)StringToInteger(value);
      else if(key == "max_spread")
         DashboardMaxSpread = (int)StringToInteger(value);
   }

   FileClose(handle);
}

void WriteDashboardStatus(int spread, bool hasPosition, double totalProfit, bool forceWrite=false)
{
   if(!InpUseDashboardControl)
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
   FileWriteString(handle, "symbol=" + _Symbol + "\n");
   FileWriteString(handle, "event_source=" + LastEventSource + "\n");
   FileWriteString(handle, "dashboard_enabled=" + BoolFlag(DashboardEnabled) + "\n");
   FileWriteString(handle, "close_all=" + BoolFlag(DashboardCloseAll) + "\n");
   FileWriteString(handle, "has_position=" + BoolFlag(hasPosition) + "\n");
   FileWriteString(handle, "spread=" + IntegerToString(spread) + "\n");
   FileWriteString(handle, "max_spread=" + IntegerToString(ActiveMaxSpread()) + "\n");
   FileWriteString(handle, "turns=" + IntegerToString(CurrentTurns) + "\n");
   FileWriteString(handle, "total_profit=" + DoubleToString(totalProfit, 2) + "\n");
   FileWriteString(handle, "upper_level=" + DoubleToString(UpperLevel, _Digits) + "\n");
   FileWriteString(handle, "lower_level=" + DoubleToString(LowerLevel, _Digits) + "\n");
   FileWriteString(handle, "cycle_id=" + CycleId + "\n");
   FileWriteString(handle, "cycle_worst_profit=" + DoubleToString(CycleWorstProfit, 2) + "\n");
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
   if(!InpUseDashboardControl)
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

double ActiveTargetUSD()
{
   return(DashboardTargetUSD > 0.0 ? DashboardTargetUSD : TargetUSD);
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
   string dashboard = InpUseDashboardControl ? (DashboardEnabled ? "RUNNING" : "PAUSED") : "LOCAL INPUTS";
   string modelStatus = InpUseAiFilter ? (ModelGateEnabled ? "ACTIVE" : "RECORDING") : "OFF";

   Comment("--- RECOVERY SHIELD ---\n",
           "Current Spread: ", spread, "\n",
           "Max Allowed: ", ActiveMaxSpread(), "\n",
           "Status: ", status, "\n",
           "Dashboard: ", dashboard, "\n",
           "AI Filter: ", modelStatus, " | Score: ", DoubleToString(LastModelScore, 3), "\n",
           "EA Message: ", LastStatus, "\n",
           "Turns: ", CurrentTurns);
}
