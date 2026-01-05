//+------------------------------------------------------------------+
//|                                           FlowsurfaceServer.mq5  |
//|                                     Flowsurface MT5 Data Bridge  |
//|                    WebSocket Client for Proxy Server Connection   |
//+------------------------------------------------------------------+
#property copyright   "Flowsurface"
#property version     "2.00"
#property description "MT5 Data Bridge - Connects to Proxy Server"
#property description "Streams real-time trades, depth, and klines"
#property strict

//--- Include modules
#include "Include/JsonBuilder.mqh"
#include "Include/Authentication.mqh"
#include "Include/WebSocketClient.mqh"

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Proxy Server Settings ==="
input string   InpProxyHost      = "localhost";       // Proxy Server Host
input int      InpProxyPort      = 9876;              // Proxy Server Port
input int      InpReconnectSec   = 5;                 // Reconnect Interval (seconds)
input int      InpHeartbeatSec   = 30;                // Heartbeat Interval (seconds)

input group "=== Security Settings ==="
input string   InpApiKey         = "your_api_key";    // API Key
input string   InpApiSecret      = "your_secret";     // API Secret

input group "=== Data Settings ==="
input string   InpSymbols        = "XAUUSD,EURUSD";   // Symbols to Stream
input bool     InpEnableDepth    = true;              // Enable Depth Data
input bool     InpEnableTrades   = true;              // Enable Trade Data
input bool     InpEnableKlines   = true;              // Enable Kline Data
input int      InpDepthLevels    = 10;                // Depth Levels to Send

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CWebSocketClient  g_client;
CAuthManager      g_auth;
CJsonBuilder      g_json;

bool              g_authenticated = false;
datetime          g_last_heartbeat = 0;
datetime          g_last_reconnect_attempt = 0;
string            g_subscribed_symbols[];
MqlTick           g_last_ticks[];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("==============================================");
    Print("Flowsurface MT5 Bridge v2.00 Starting...");
    Print("==============================================");
    
    //--- Initialize authentication
    g_auth.SetCredentials(InpApiKey, InpApiSecret);
    
    //--- Parse symbols
    ParseSymbols(InpSymbols);
    
    //--- Initialize tick storage
    ArrayResize(g_last_ticks, ArraySize(g_subscribed_symbols));
    
    //--- Subscribe to market book for depth data
    if(InpEnableDepth)
    {
        for(int i = 0; i < ArraySize(g_subscribed_symbols); i++)
        {
            if(MarketBookAdd(g_subscribed_symbols[i]))
                Print("Subscribed to MarketBook: ", g_subscribed_symbols[i]);
            else
                Print("Warning: Failed to subscribe to MarketBook for ", g_subscribed_symbols[i]);
        }
    }
    
    Print("Proxy: ", InpProxyHost, ":", InpProxyPort);
    Print("Symbols: ", InpSymbols);
    Print("==============================================");
    
    //--- Set timer for periodic tasks
    EventSetMillisecondTimer(100);
    
    //--- Attempt initial connection
    ConnectToProxy();
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    
    //--- Unsubscribe from market books
    for(int i = 0; i < ArraySize(g_subscribed_symbols); i++)
    {
        MarketBookRelease(g_subscribed_symbols[i]);
    }
    
    //--- Disconnect from proxy
    g_client.Disconnect();
    
    Print("Flowsurface MT5 Bridge stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function - Main loop                                        |
//+------------------------------------------------------------------+
void OnTimer()
{
    //--- Check connection and reconnect if needed
    if(!g_client.IsConnected())
    {
        if(TimeCurrent() - g_last_reconnect_attempt >= InpReconnectSec)
        {
            ConnectToProxy();
            g_last_reconnect_attempt = TimeCurrent();
        }
        return;
    }
    
    //--- Process incoming messages
    ProcessIncomingMessages();
    
    //--- Send heartbeat
    if(g_authenticated && TimeCurrent() - g_last_heartbeat >= InpHeartbeatSec)
    {
        SendHeartbeat();
        g_last_heartbeat = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
//| Tick function - Trade data                                        |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!InpEnableTrades) return;
    if(!g_client.IsConnected() || !g_authenticated) return;
    
    string symbol = Symbol();
    MqlTick tick;
    
    if(!SymbolInfoTick(symbol, tick))
        return;
    
    //--- Find symbol index
    int idx = FindSymbolIndex(symbol);
    if(idx < 0) return;
    
    //--- Check if tick changed
    if(g_last_ticks[idx].time == tick.time && 
       g_last_ticks[idx].last == tick.last)
        return;
    
    //--- Determine side
    string side = "unknown";
    if(tick.last > g_last_ticks[idx].last)
        side = "buy";
    else if(tick.last < g_last_ticks[idx].last)
        side = "sell";
    
    //--- Build and send trade message
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "trade");
    g_json.AddKeyValue("symbol", symbol);
    g_json.AddKeyValue("time", (long)(tick.time_msc));
    g_json.AddKeyValue("price", tick.last, 5);
    g_json.AddKeyValue("volume", tick.volume_real, 2);
    g_json.AddKeyValue("side", side);
    g_json.EndObject();
    
    g_client.SendText(g_json.ToString());
    
    //--- Store last tick
    g_last_ticks[idx] = tick;
}

//+------------------------------------------------------------------+
//| Book event - Depth data                                           |
//+------------------------------------------------------------------+
void OnBookEvent(const string& symbol)
{
    if(!InpEnableDepth) return;
    if(!g_client.IsConnected() || !g_authenticated) return;
    
    MqlBookInfo book[];
    if(!MarketBookGet(symbol, book))
        return;
    
    int book_size = ArraySize(book);
    if(book_size == 0) return;
    
    //--- Build depth message
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "depth");
    g_json.AddKeyValue("symbol", symbol);
    g_json.AddKeyValue("time", (long)TimeTradeServer() * 1000 + GetTickCount() % 1000);
    
    //--- Bids array
    g_json.AddKeyArray("bids");
    int bid_count = 0;
    for(int i = 0; i < book_size && bid_count < InpDepthLevels; i++)
    {
        if(book[i].type == BOOK_TYPE_BUY || book[i].type == BOOK_TYPE_BUY_MARKET)
        {
            g_json.StartArray();
            g_json.AddDouble(book[i].price, 5);
            g_json.AddDouble(book[i].volume_real, 2);
            g_json.EndArray();
            bid_count++;
        }
    }
    g_json.EndArray();
    
    //--- Asks array
    g_json.AddKeyArray("asks");
    int ask_count = 0;
    for(int i = 0; i < book_size && ask_count < InpDepthLevels; i++)
    {
        if(book[i].type == BOOK_TYPE_SELL || book[i].type == BOOK_TYPE_SELL_MARKET)
        {
            g_json.StartArray();
            g_json.AddDouble(book[i].price, 5);
            g_json.AddDouble(book[i].volume_real, 2);
            g_json.EndArray();
            ask_count++;
        }
    }
    g_json.EndArray();
    
    g_json.EndObject();
    
    g_client.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Connect to proxy server                                           |
//+------------------------------------------------------------------+
void ConnectToProxy()
{
    Print("Connecting to proxy server: ", InpProxyHost, ":", InpProxyPort);
    
    if(!g_client.Connect(InpProxyHost, InpProxyPort, "/mt5"))
    {
        Print("Failed to connect to proxy server");
        return;
    }
    
    Print("Connected to proxy server, sending authentication...");
    g_authenticated = false;
    
    //--- Send authentication
    long timestamp = g_auth.GetCurrentTimestampMs();
    string signature = g_auth.ComputeSignature(InpApiKey, timestamp);
    
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "auth");
    g_json.AddKeyValue("api_key", InpApiKey);
    g_json.AddKeyValue("timestamp", timestamp);
    g_json.AddKeyValue("signature", signature);
    g_json.EndObject();
    
    g_client.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Process incoming messages from proxy                              |
//+------------------------------------------------------------------+
void ProcessIncomingMessages()
{
    string message;
    while(g_client.ReceiveText(message, 10))
    {
        HandleProxyMessage(message);
    }
}

//+------------------------------------------------------------------+
//| Handle message from proxy server                                  |
//+------------------------------------------------------------------+
void HandleProxyMessage(const string message)
{
    CJsonParser parser;
    if(!parser.Parse(message))
    {
        Print("Failed to parse message from proxy");
        return;
    }
    
    string msg_type;
    if(!parser.GetString("type", msg_type))
        return;
    
    if(msg_type == "auth_response")
    {
        bool success = false;
        parser.GetBool("success", success);
        
        if(success)
        {
            g_authenticated = true;
            Print("Authentication successful!");
            
            //--- Send available symbols
            SendSymbolsInfo();
        }
        else
        {
            string error;
            parser.GetString("error", error);
            Print("Authentication failed: ", error);
            g_client.Disconnect();
        }
    }
    else if(msg_type == "heartbeat")
    {
        // Heartbeat received, connection is alive
    }
    else if(msg_type == "get_klines")
    {
        HandleGetKlinesRequest(parser);
    }
    else if(msg_type == "ping")
    {
        SendPong();
    }
}

//+------------------------------------------------------------------+
//| Send symbols info to proxy                                        |
//+------------------------------------------------------------------+
void SendSymbolsInfo()
{
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "symbols");
    g_json.AddKeyArray("data");
    
    for(int i = 0; i < ArraySize(g_subscribed_symbols); i++)
    {
        string sym = g_subscribed_symbols[i];
        double tick_size = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
        double min_lot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
        double contract = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
        int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
        
        g_json.StartObject();
        g_json.AddKeyValue("symbol", sym);
        g_json.AddKeyValue("tick_size", tick_size, digits);
        g_json.AddKeyValue("min_lot", min_lot, 2);
        g_json.AddKeyValue("contract_size", contract, 2);
        g_json.AddKeyValue("digits", (long)digits);
        g_json.EndObject();
    }
    
    g_json.EndArray();
    g_json.EndObject();
    
    g_client.SendText(g_json.ToString());
    Print("Sent symbols info: ", ArraySize(g_subscribed_symbols), " symbols");
}

//+------------------------------------------------------------------+
//| Handle get klines request                                         |
//+------------------------------------------------------------------+
void HandleGetKlinesRequest(CJsonParser& parser)
{
    string symbol;
    string timeframe_str;
    long start_time = 0;
    long end_time = 0;
    long limit = 500;
    double request_id = 0;
    
    parser.GetString("symbol", symbol);
    parser.GetString("timeframe", timeframe_str);
    parser.GetLong("start", start_time);
    parser.GetLong("end", end_time);
    parser.GetLong("limit", limit);
    parser.GetDouble("request_id", request_id);
    
    ENUM_TIMEFRAMES tf = StringToTimeframe(timeframe_str);
    if(tf == PERIOD_CURRENT)
        tf = PERIOD_M1;
    
    //--- Fetch rates
    MqlRates rates[];
    int count;
    
    if(start_time > 0 && end_time > 0)
    {
        count = CopyRates(symbol, tf, (datetime)(start_time/1000), (datetime)(end_time/1000), rates);
    }
    else
    {
        count = CopyRates(symbol, tf, 0, (int)MathMin(limit, 1000), rates);
    }
    
    if(count <= 0)
    {
        g_json.Reset();
        g_json.StartObject();
        g_json.AddKeyValue("type", "error");
        g_json.AddKeyValue("message", "Failed to get klines for " + symbol);
        if(request_id > 0)
            g_json.AddKeyValue("request_id", request_id, 0);
        g_json.EndObject();
        g_client.SendText(g_json.ToString());
        return;
    }
    
    //--- Build response
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "klines");
    g_json.AddKeyValue("symbol", symbol);
    g_json.AddKeyValue("timeframe", timeframe_str);
    if(request_id > 0)
        g_json.AddKeyValue("request_id", request_id, 0);
    g_json.AddKeyArray("data");
    
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    
    for(int i = 0; i < count; i++)
    {
        g_json.StartObject();
        g_json.AddKeyValue("time", (long)rates[i].time * 1000);
        g_json.AddKeyValue("open", rates[i].open, digits);
        g_json.AddKeyValue("high", rates[i].high, digits);
        g_json.AddKeyValue("low", rates[i].low, digits);
        g_json.AddKeyValue("close", rates[i].close, digits);
        g_json.AddKeyValue("volume", rates[i].real_volume, 2);
        g_json.AddKeyValue("tick_volume", (long)rates[i].tick_volume);
        g_json.EndObject();
    }
    
    g_json.EndArray();
    g_json.EndObject();
    
    g_client.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Send heartbeat to proxy                                           |
//+------------------------------------------------------------------+
void SendHeartbeat()
{
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "ping");
    g_json.AddKeyValue("time", g_auth.GetCurrentTimestampMs());
    g_json.EndObject();
    
    g_client.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Send pong response                                                |
//+------------------------------------------------------------------+
void SendPong()
{
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "pong");
    g_json.AddKeyValue("time", g_auth.GetCurrentTimestampMs());
    g_json.EndObject();
    
    g_client.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Parse symbol list from input string                               |
//+------------------------------------------------------------------+
void ParseSymbols(const string symbols_str)
{
    string parts[];
    int count = StringSplit(symbols_str, ',', parts);
    
    ArrayResize(g_subscribed_symbols, 0);
    
    for(int i = 0; i < count; i++)
    {
        string sym = parts[i];
        StringTrimLeft(sym);
        StringTrimRight(sym);
        
        if(StringLen(sym) > 0 && SymbolSelect(sym, true))
        {
            int size = ArraySize(g_subscribed_symbols);
            ArrayResize(g_subscribed_symbols, size + 1);
            g_subscribed_symbols[size] = sym;
        }
        else if(StringLen(sym) > 0)
        {
            Print("Warning: Symbol not available: ", sym);
        }
    }
}

//+------------------------------------------------------------------+
//| Find symbol index in subscribed array                             |
//+------------------------------------------------------------------+
int FindSymbolIndex(const string symbol)
{
    for(int i = 0; i < ArraySize(g_subscribed_symbols); i++)
    {
        if(g_subscribed_symbols[i] == symbol)
            return i;
    }
    return -1;
}

//+------------------------------------------------------------------+
//| Convert timeframe string to ENUM_TIMEFRAMES                       |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES StringToTimeframe(const string tf_str)
{
    if(tf_str == "M1")  return PERIOD_M1;
    if(tf_str == "M5")  return PERIOD_M5;
    if(tf_str == "M15") return PERIOD_M15;
    if(tf_str == "M30") return PERIOD_M30;
    if(tf_str == "H1")  return PERIOD_H1;
    if(tf_str == "H4")  return PERIOD_H4;
    if(tf_str == "D1")  return PERIOD_D1;
    if(tf_str == "W1")  return PERIOD_W1;
    if(tf_str == "MN1") return PERIOD_MN1;
    return PERIOD_CURRENT;
}
//+------------------------------------------------------------------+
