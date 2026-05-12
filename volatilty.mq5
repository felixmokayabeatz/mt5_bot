//+------------------------------------------------------------------+
//|                                     RecoveryZone_Shielded_V1.mq5 |
//|                                  Copyright 2026, Gemini Academic |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

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
string         LastEventSource = "init";

int OnInit() {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(20);
   ReadDashboardControl();
   EventSetTimer(1);
   SetStatus("EA initialized on " + _Symbol + ". Waiting for dashboard command.");
   Comment("--- RECOVERY SHIELD ---\n",
           "Status: ", LastStatus, "\n",
           "If no trade opens, check the Experts tab.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
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

   ReadDashboardControl();

   // 1. DASHBOARD
   DrawDashboard(spread);

   if(!TradingAllowed())
   {
      SetStatus("Trading blocked by terminal, EA settings, account, or symbol mode.");
      DrawDashboard(spread);
      WriteDashboardStatus(spread, false, 0.0);
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

   if(DashboardCloseAll)
   {
      if(hasPosition)
      {
         SetStatus("Dashboard close-all command received.");
         CloseAll();
         ResetEA();
      }
      else
      {
         SetStatus("Dashboard close-all command received. No positions found.");
      }

      AcknowledgeCloseAllCommand();
      WriteDashboardStatus(spread, false, 0.0);
      return;
   }

   // 3. EMERGENCY EXIT (Profit Target OR Time-Out)
   if(hasPosition) {
      bool timeOut = (TimeCurrent() - CycleStartTime >= InpMaxCycleTime);
      
      if(totalProfit >= ActiveTargetUSD() || timeOut) {
         if(timeOut) Print("SHIELD: Cycle timed out. Closing to prevent 24hr trap.");
         CloseAll();
         ResetEA();
         WriteDashboardStatus(spread, false, 0.0);
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

      double entryLot = NormalizeVolume(ActiveInitialLot());
      if(trade.Buy(entryLot, _Symbol, ask, 0, 0))
      {
         if(TradeSucceeded())
         {
            UpperLevel = ask;
            LowerLevel = ask - (ActiveZoneHeight() * _Point);
            CurrentTurns = 1;
            CycleStartTime = TimeCurrent();
            SetStatus("Initial BUY opened.");
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
      WriteDashboardStatus(spread, HasManagedPosition(), CurrentManagedProfit());
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
         }
         else
         {
            LogTradeFailure("Recovery BUY");
         }
      }
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

void ResetEA() {
   UpperLevel = 0; LowerLevel = 0; CurrentTurns = 0; CycleStartTime = 0;
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

void ReadDashboardControl()
{
   if(!InpUseDashboardControl)
   {
      DashboardEnabled = true;
      DashboardCloseAll = false;
      return;
   }

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

void WriteDashboardStatus(int spread, bool hasPosition, double totalProfit)
{
   if(!InpUseDashboardControl)
      return;

   if(LastStatusWrite != 0 && TimeCurrent() - LastStatusWrite < 2)
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
   string status = (spread <= ActiveMaxSpread()) ? "SAFE" : "TOXIC SPREAD";
   string dashboard = InpUseDashboardControl ? (DashboardEnabled ? "RUNNING" : "PAUSED") : "LOCAL INPUTS";

   Comment("--- RECOVERY SHIELD ---\n",
           "Current Spread: ", spread, "\n",
           "Max Allowed: ", ActiveMaxSpread(), "\n",
           "Status: ", status, "\n",
           "Dashboard: ", dashboard, "\n",
           "EA Message: ", LastStatus, "\n",
           "Turns: ", CurrentTurns);
}
