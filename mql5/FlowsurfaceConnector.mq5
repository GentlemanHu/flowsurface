//+------------------------------------------------------------------+
//|                                         FlowsurfaceConnector.mq5 |
//|                                    Copyright 2024, Flowsurface   |
//|                                     https://flowsurface.com      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Flowsurface"
#property link      "https://flowsurface.com"
#property version   "1.00"
#property description "Expert Advisor to send MT5 market data to Flowsurface application"

//--- Input parameters
input string   FlowsurfaceHost = "127.0.0.1";  // Flowsurface server host
input int      FlowsurfacePort = 7878;          // Flowsurface server port
input int      DepthLevels = 10;                // Number of depth levels to send
input bool     SendTrades = true;               // Send trade data
input bool     SendDepth = true;                // Send depth data
input bool     SendKlines = true;               // Send kline data
input int      UpdateIntervalMs = 100;          // Update interval in milliseconds

//--- Global variables
int socket = INVALID_HANDLE;
datetime lastKlineTime = 0;
bool isConnected = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("Flowsurface Connector EA starting...");
    
    // Connect to Flowsurface server
    if(!ConnectToFlowsurface())
    {
        Print("Failed to connect to Flowsurface at ", FlowsurfaceHost, ":", FlowsurfacePort);
        return(INIT_FAILED);
    }
    
    Print("Successfully connected to Flowsurface");
    
    // Send ticker info on startup
    SendTickerInfo();
    
    // Set timer for periodic updates
    EventSetMillisecondTimer(UpdateIntervalMs);
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    
    if(socket != INVALID_HANDLE)
    {
        SocketClose(socket);
        socket = INVALID_HANDLE;
    }
    
    Print("Flowsurface Connector EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function                                                    |
//+------------------------------------------------------------------+
void OnTimer()
{
    // Ensure connection is alive
    if(!isConnected && !ConnectToFlowsurface())
    {
        return;
    }
    
    // Send market depth
    if(SendDepth)
    {
        SendMarketDepth();
    }
    
    // Send klines periodically
    if(SendKlines)
    {
        datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
        if(currentBarTime != lastKlineTime)
        {
            SendKlineData();
            lastKlineTime = currentBarTime;
        }
    }
}

//+------------------------------------------------------------------+
//| Trade event handler                                              |
//+------------------------------------------------------------------+
void OnTrade()
{
    if(SendTrades && isConnected)
    {
        SendTradeData();
    }
}

//+------------------------------------------------------------------+
//| Book event handler (market depth changes)                        |
//+------------------------------------------------------------------+
void OnBookEvent(const string &symbol)
{
    if(_Symbol == symbol && SendDepth && isConnected)
    {
        SendMarketDepth();
    }
}

//+------------------------------------------------------------------+
//| Connect to Flowsurface server                                    |
//+------------------------------------------------------------------+
bool ConnectToFlowsurface()
{
    if(socket != INVALID_HANDLE)
    {
        SocketClose(socket);
        socket = INVALID_HANDLE;
    }
    
    socket = SocketCreate();
    if(socket == INVALID_HANDLE)
    {
        Print("Failed to create socket: ", GetLastError());
        isConnected = false;
        return false;
    }
    
    if(!SocketConnect(socket, FlowsurfaceHost, FlowsurfacePort, 5000))
    {
        Print("Failed to connect socket: ", GetLastError());
        SocketClose(socket);
        socket = INVALID_HANDLE;
        isConnected = false;
        return false;
    }
    
    isConnected = true;
    return true;
}

//+------------------------------------------------------------------+
//| Send ticker information                                          |
//+------------------------------------------------------------------+
void SendTickerInfo()
{
    string json = "{";
    json += "\"type\":\"ticker_info\",";
    json += "\"symbol\":\"" + _Symbol + "\",";
    json += "\"tick_size\":" + DoubleToString(_Point, 8) + ",";
    json += "\"min_qty\":" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), 8) + ",";
    json += "\"digits\":" + IntegerToString(_Digits);
    json += "}\n";
    
    SendData(json);
}

//+------------------------------------------------------------------+
//| Send trade data                                                  |
//+------------------------------------------------------------------+
void SendTradeData()
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick))
    {
        return;
    }
    
    string json = "{";
    json += "\"type\":\"trade\",";
    json += "\"symbol\":\"" + _Symbol + "\",";
    json += "\"time\":" + IntegerToString(tick.time_msc) + ",";
    json += "\"price\":" + DoubleToString(tick.last, _Digits) + ",";
    json += "\"volume\":" + DoubleToString(tick.volume, 8) + ",";
    json += "\"is_sell\":" + (tick.flags & TICK_FLAG_SELL ? "true" : "false");
    json += "}\n";
    
    SendData(json);
}

//+------------------------------------------------------------------+
//| Send market depth data                                           |
//+------------------------------------------------------------------+
void SendMarketDepth()
{
    MqlBookInfo book[];
    if(!MarketBookGet(_Symbol, book))
    {
        return;
    }
    
    string bids = "[";
    string asks = "[";
    int bidCount = 0;
    int askCount = 0;
    
    for(int i = 0; i < ArraySize(book) && (bidCount < DepthLevels || askCount < DepthLevels); i++)
    {
        if(book[i].type == BOOK_TYPE_BUY && bidCount < DepthLevels)
        {
            if(bidCount > 0) bids += ",";
            bids += "[" + DoubleToString(book[i].price, _Digits) + "," + DoubleToString(book[i].volume, 8) + "]";
            bidCount++;
        }
        else if(book[i].type == BOOK_TYPE_SELL && askCount < DepthLevels)
        {
            if(askCount > 0) asks += ",";
            asks += "[" + DoubleToString(book[i].price, _Digits) + "," + DoubleToString(book[i].volume, 8) + "]";
            askCount++;
        }
    }
    
    bids += "]";
    asks += "]";
    
    MqlTick tick;
    SymbolInfoTick(_Symbol, tick);
    
    string json = "{";
    json += "\"type\":\"depth\",";
    json += "\"symbol\":\"" + _Symbol + "\",";
    json += "\"time\":" + IntegerToString(tick.time_msc) + ",";
    json += "\"bids\":" + bids + ",";
    json += "\"asks\":" + asks;
    json += "}\n";
    
    SendData(json);
}

//+------------------------------------------------------------------+
//| Send kline/candlestick data                                      |
//+------------------------------------------------------------------+
void SendKlineData()
{
    MqlRates rates[];
    if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 1, rates) <= 0)
    {
        return;
    }
    
    // Convert ENUM_TIMEFRAMES to string
    string timeframe = PeriodToString(PERIOD_CURRENT);
    
    string json = "{";
    json += "\"type\":\"kline\",";
    json += "\"symbol\":\"" + _Symbol + "\",";
    json += "\"time\":" + IntegerToString(rates[0].time * 1000) + ","; // Convert to milliseconds
    json += "\"open\":" + DoubleToString(rates[0].open, _Digits) + ",";
    json += "\"high\":" + DoubleToString(rates[0].high, _Digits) + ",";
    json += "\"low\":" + DoubleToString(rates[0].low, _Digits) + ",";
    json += "\"close\":" + DoubleToString(rates[0].close, _Digits) + ",";
    json += "\"volume\":" + DoubleToString(rates[0].tick_volume, 8) + ",";
    json += "\"timeframe\":\"" + timeframe + "\"";
    json += "}\n";
    
    SendData(json);
}

//+------------------------------------------------------------------+
//| Send data through socket                                         |
//+------------------------------------------------------------------+
void SendData(string data)
{
    if(socket == INVALID_HANDLE || !isConnected)
    {
        return;
    }
    
    uchar buffer[];
    StringToCharArray(data, buffer, 0, StringLen(data));
    
    int sent = SocketSend(socket, buffer, ArraySize(buffer));
    if(sent < 0)
    {
        Print("Failed to send data: ", GetLastError());
        isConnected = false;
        SocketClose(socket);
        socket = INVALID_HANDLE;
    }
}

//+------------------------------------------------------------------+
//| Convert period to string                                         |
//+------------------------------------------------------------------+
string PeriodToString(ENUM_TIMEFRAMES period)
{
    switch(period)
    {
        case PERIOD_M1:  return "M1";
        case PERIOD_M2:  return "M2";
        case PERIOD_M3:  return "M3";
        case PERIOD_M4:  return "M4";
        case PERIOD_M5:  return "M5";
        case PERIOD_M6:  return "M6";
        case PERIOD_M10: return "M10";
        case PERIOD_M12: return "M12";
        case PERIOD_M15: return "M15";
        case PERIOD_M20: return "M20";
        case PERIOD_M30: return "M30";
        case PERIOD_H1:  return "H1";
        case PERIOD_H2:  return "H2";
        case PERIOD_H3:  return "H3";
        case PERIOD_H4:  return "H4";
        case PERIOD_H6:  return "H6";
        case PERIOD_H8:  return "H8";
        case PERIOD_H12: return "H12";
        case PERIOD_D1:  return "D1";
        case PERIOD_W1:  return "W1";
        case PERIOD_MN1: return "MN1";
        default:         return "M1";
    }
}
//+------------------------------------------------------------------+
