//+------------------------------------------------------------------+
//|                                           FlowsurfaceServer.mq5  |
//|                                     Flowsurface MT5 Data Bridge  |
//|                    WebSocket Server for Real-time Market Data    |
//+------------------------------------------------------------------+
#property copyright   "Flowsurface"
#property version     "1.00"
#property description "MT5 WebSocket Server for Flowsurface Desktop App"
#property description "Streams real-time trades, depth, and klines via WebSocket"
#property strict

//--- Include modules
#include "Include/JsonBuilder.mqh"
#include "Include/Authentication.mqh"
#include "Include/WebSocketServer.mqh"

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== Server Settings ==="
input int      InpServerPort     = 9876;            // WebSocket Server Port
input int      InpHeartbeatSec   = 30;              // Heartbeat Interval (seconds)
input int      InpSessionTimeout = 300;             // Session Timeout (seconds)

input group "=== Security Settings ==="
input string   InpApiKey         = "your_api_key";  // API Key
input string   InpApiSecret      = "your_secret";   // API Secret (keep private!)
input string   InpAllowedIPs     = "";              // Allowed IPs (comma-separated, empty=all)
input int      InpTimestampTolerance = 30000;       // Timestamp Tolerance (ms)

input group "=== Data Settings ==="
input string   InpSymbols        = "XAUUSD,EURUSD"; // Default Symbols
input bool     InpEnableDepth    = true;            // Enable Depth Data
input bool     InpEnableTrades   = true;            // Enable Trade Data
input bool     InpEnableKlines   = true;            // Enable Kline Data
input int      InpDepthLevels    = 10;              // Depth Levels to Send

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CWebSocketServer  g_server;
CAuthManager      g_auth;
CClientSession    g_sessions[];
CJsonBuilder      g_json;

datetime          g_last_heartbeat = 0;
string            g_subscribed_symbols[];
MqlTick           g_last_ticks[];

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("==============================================");
    Print("Flowsurface MT5 Server v1.00 Starting...");
    Print("==============================================");
    
    //--- Initialize authentication
    g_auth.SetCredentials(InpApiKey, InpApiSecret);
    g_auth.SetTimestampTolerance(InpTimestampTolerance);
    
    //--- Parse allowed IPs
    if(StringLen(InpAllowedIPs) > 0)
    {
        string ips[];
        int count = StringSplit(InpAllowedIPs, ',', ips);
        for(int i = 0; i < count; i++)
        {
            string ip = ips[i];
            StringTrimLeft(ip);
            StringTrimRight(ip);
            if(StringLen(ip) > 0)
                g_auth.AddAllowedIP(ip);
        }
    }
    
    //--- Parse default symbols
    ParseSymbols(InpSymbols);
    
    //--- Initialize tick storage
    ArrayResize(g_last_ticks, ArraySize(g_subscribed_symbols));
    
    //--- Subscribe to market book for depth data
    if(InpEnableDepth)
    {
        for(int i = 0; i < ArraySize(g_subscribed_symbols); i++)
        {
            if(!MarketBookAdd(g_subscribed_symbols[i]))
            {
                Print("Warning: Failed to subscribe to MarketBook for ", g_subscribed_symbols[i]);
            }
            else
            {
                Print("Subscribed to MarketBook: ", g_subscribed_symbols[i]);
            }
        }
    }
    
    //--- Start WebSocket server
    if(!g_server.Start(InpServerPort))
    {
        Print("ERROR: Failed to start WebSocket server!");
        return INIT_FAILED;
    }
    
    //--- Initialize sessions array
    ArrayResize(g_sessions, 10);
    
    Print("Server started on port ", InpServerPort);
    Print("API Key: ", StringSubstr(InpApiKey, 0, 4), "****");
    Print("Symbols: ", InpSymbols);
    Print("==============================================");
    
    //--- Set timer for periodic tasks
    EventSetMillisecondTimer(100);
    
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
    
    //--- Stop server
    g_server.Stop();
    
    Print("Flowsurface MT5 Server stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Timer function - Main loop                                        |
//+------------------------------------------------------------------+
void OnTimer()
{
    //--- Check for heartbeat
    if(TimeCurrent() - g_last_heartbeat >= InpHeartbeatSec)
    {
        SendHeartbeat();
        g_last_heartbeat = TimeCurrent();
    }
    
    //--- Check session timeouts
    CheckSessionTimeouts();
    
    //--- Process pending messages (if any)
    ProcessPendingMessages();
}

//+------------------------------------------------------------------+
//| Tick function - Trade data                                        |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!InpEnableTrades) return;
    if(g_server.GetConnectedCount() == 0) return;
    
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
    
    //--- Determine if buy or sell based on price movement
    string side = "unknown";
    if(tick.last > g_last_ticks[idx].last)
        side = "buy";
    else if(tick.last < g_last_ticks[idx].last)
        side = "sell";
    
    //--- Build trade message
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "trade");
    g_json.AddKeyValue("symbol", symbol);
    g_json.AddKeyValue("time", (long)(tick.time_msc));
    g_json.AddKeyValue("price", tick.last, 5);
    g_json.AddKeyValue("volume", tick.volume_real, 2);
    g_json.AddKeyValue("side", side);
    g_json.EndObject();
    
    //--- Broadcast to authenticated clients
    BroadcastToSubscribed(symbol, g_json.ToString());
    
    //--- Store last tick
    g_last_ticks[idx] = tick;
}

//+------------------------------------------------------------------+
//| Book event - Depth data                                           |
//+------------------------------------------------------------------+
void OnBookEvent(const string& symbol)
{
    if(!InpEnableDepth) return;
    if(g_server.GetConnectedCount() == 0) return;
    
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
    
    //--- Broadcast to subscribed clients
    BroadcastToSubscribed(symbol, g_json.ToString());
}

//+------------------------------------------------------------------+
//| Process incoming WebSocket messages                               |
//+------------------------------------------------------------------+
void ProcessPendingMessages()
{
    for(int i = 0; i < ArraySize(g_sessions); i++)
    {
        if(!g_sessions[i].is_authenticated) continue;
        
        CWebSocketConnection* conn = g_server.GetClient(i);
        if(conn == NULL || !conn.IsConnected()) continue;
        
        WebSocketFrame frame;
        if(!conn.ReceiveFrame(frame)) continue;
        
        g_sessions[i].UpdateActivity();
        
        switch(frame.opcode)
        {
            case WS_OPCODE_TEXT:
                HandleClientMessage(i, CharArrayToString(frame.payload));
                break;
                
            case WS_OPCODE_PING:
                // Send pong
                uchar pong[];
                ArrayCopy(pong, frame.payload);
                conn.SendFrame(WS_OPCODE_PONG, pong);
                break;
                
            case WS_OPCODE_CLOSE:
                Print("Client ", i, " sent close frame");
                DisconnectClient(i);
                break;
        }
    }
}

//+------------------------------------------------------------------+
//| Handle client message                                             |
//+------------------------------------------------------------------+
void HandleClientMessage(int client_index, const string message)
{
    CJsonParser parser;
    if(!parser.Parse(message))
    {
        Print("Failed to parse message from client ", client_index);
        return;
    }
    
    string msg_type;
    if(!parser.GetString("type", msg_type))
    {
        Print("Message missing 'type' field");
        return;
    }
    
    if(msg_type == "auth")
    {
        HandleAuthMessage(client_index, parser);
    }
    else if(msg_type == "subscribe")
    {
        HandleSubscribeMessage(client_index, parser);
    }
    else if(msg_type == "unsubscribe")
    {
        HandleUnsubscribeMessage(client_index, parser);
    }
    else if(msg_type == "get_symbols")
    {
        HandleGetSymbolsMessage(client_index);
    }
    else if(msg_type == "get_klines")
    {
        HandleGetKlinesMessage(client_index, parser);
    }
    else if(msg_type == "ping")
    {
        SendPong(client_index);
    }
}

//+------------------------------------------------------------------+
//| Handle authentication message                                     |
//+------------------------------------------------------------------+
void HandleAuthMessage(int client_index, CJsonParser& parser)
{
    string api_key, signature;
    long timestamp;
    
    parser.GetString("api_key", api_key);
    parser.GetLong("timestamp", timestamp);
    parser.GetString("signature", signature);
    
    string error_msg;
    bool success = g_auth.ValidateAuth(api_key, timestamp, signature, 
                                       g_sessions[client_index].client_ip, error_msg);
    
    //--- Build response
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "auth_response");
    g_json.AddKeyValue("success", success);
    
    if(success)
    {
        g_sessions[client_index].is_authenticated = true;
        g_sessions[client_index].auth_time = (long)TimeCurrent() * 1000;
        g_json.AddKeyValue("server_time", g_auth.GetCurrentTimestampMs());
        Print("Client ", client_index, " authenticated successfully");
    }
    else
    {
        g_json.AddKeyValue("error", error_msg);
        Print("Client ", client_index, " auth failed: ", error_msg);
    }
    
    g_json.EndObject();
    
    CWebSocketConnection* conn = g_server.GetClient(client_index);
    if(conn != NULL)
        conn.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Handle subscribe message                                          |
//+------------------------------------------------------------------+
void HandleSubscribeMessage(int client_index, CJsonParser& parser)
{
    if(!g_sessions[client_index].is_authenticated)
    {
        SendError(client_index, "Not authenticated");
        return;
    }
    
    // Parse symbols and channels from message
    // For simplicity, subscribe to all configured symbols
    for(int i = 0; i < ArraySize(g_subscribed_symbols); i++)
    {
        g_sessions[client_index].AddSubscription(g_subscribed_symbols[i]);
    }
    
    g_sessions[client_index].subscribe_depth = InpEnableDepth;
    g_sessions[client_index].subscribe_trades = InpEnableTrades;
    g_sessions[client_index].subscribe_klines = InpEnableKlines;
    
    //--- Send confirmation
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "subscribed");
    g_json.AddKeyArray("symbols");
    for(int i = 0; i < ArraySize(g_subscribed_symbols); i++)
    {
        g_json.AddString(g_subscribed_symbols[i]);
    }
    g_json.EndArray();
    g_json.EndObject();
    
    CWebSocketConnection* conn = g_server.GetClient(client_index);
    if(conn != NULL)
        conn.SendText(g_json.ToString());
    
    Print("Client ", client_index, " subscribed to ", ArraySize(g_subscribed_symbols), " symbols");
}

//+------------------------------------------------------------------+
//| Handle unsubscribe message                                        |
//+------------------------------------------------------------------+
void HandleUnsubscribeMessage(int client_index, CJsonParser& parser)
{
    ArrayResize(g_sessions[client_index].subscribed_symbols, 0);
    
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "unsubscribed");
    g_json.EndObject();
    
    CWebSocketConnection* conn = g_server.GetClient(client_index);
    if(conn != NULL)
        conn.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Handle get symbols request                                        |
//+------------------------------------------------------------------+
void HandleGetSymbolsMessage(int client_index)
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
    
    CWebSocketConnection* conn = g_server.GetClient(client_index);
    if(conn != NULL)
        conn.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Handle get klines request                                         |
//+------------------------------------------------------------------+
void HandleGetKlinesMessage(int client_index, CJsonParser& parser)
{
    string symbol;
    string timeframe_str;
    long start_time = 0;
    long end_time = 0;
    long limit = 500;
    
    parser.GetString("symbol", symbol);
    parser.GetString("timeframe", timeframe_str);
    parser.GetLong("start", start_time);
    parser.GetLong("end", end_time);
    parser.GetLong("limit", limit);
    
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
        SendError(client_index, "Failed to get klines for " + symbol);
        return;
    }
    
    //--- Build response
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "klines");
    g_json.AddKeyValue("symbol", symbol);
    g_json.AddKeyValue("timeframe", timeframe_str);
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
    
    CWebSocketConnection* conn = g_server.GetClient(client_index);
    if(conn != NULL)
        conn.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Broadcast message to clients subscribed to symbol                 |
//+------------------------------------------------------------------+
void BroadcastToSubscribed(const string symbol, const string message)
{
    for(int i = 0; i < ArraySize(g_sessions); i++)
    {
        if(!g_sessions[i].is_authenticated) continue;
        if(!g_sessions[i].IsSubscribed(symbol)) continue;
        
        CWebSocketConnection* conn = g_server.GetClient(i);
        if(conn != NULL && conn.IsConnected())
        {
            conn.SendText(message);
        }
    }
}

//+------------------------------------------------------------------+
//| Send heartbeat to all clients                                     |
//+------------------------------------------------------------------+
void SendHeartbeat()
{
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "heartbeat");
    g_json.AddKeyValue("time", g_auth.GetCurrentTimestampMs());
    g_json.EndObject();
    
    g_server.Broadcast(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Send pong response                                                |
//+------------------------------------------------------------------+
void SendPong(int client_index)
{
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "pong");
    g_json.AddKeyValue("time", g_auth.GetCurrentTimestampMs());
    g_json.EndObject();
    
    CWebSocketConnection* conn = g_server.GetClient(client_index);
    if(conn != NULL)
        conn.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Send error response                                               |
//+------------------------------------------------------------------+
void SendError(int client_index, const string error_msg)
{
    g_json.Reset();
    g_json.StartObject();
    g_json.AddKeyValue("type", "error");
    g_json.AddKeyValue("message", error_msg);
    g_json.EndObject();
    
    CWebSocketConnection* conn = g_server.GetClient(client_index);
    if(conn != NULL)
        conn.SendText(g_json.ToString());
}

//+------------------------------------------------------------------+
//| Check and disconnect expired sessions                             |
//+------------------------------------------------------------------+
void CheckSessionTimeouts()
{
    long timeout_ms = InpSessionTimeout * 1000;
    
    for(int i = 0; i < ArraySize(g_sessions); i++)
    {
        if(g_sessions[i].is_authenticated && g_sessions[i].IsExpired(timeout_ms))
        {
            Print("Session ", i, " timed out");
            DisconnectClient(i);
        }
    }
}

//+------------------------------------------------------------------+
//| Disconnect client                                                 |
//+------------------------------------------------------------------+
void DisconnectClient(int client_index)
{
    g_server.RemoveClient(client_index);
    g_sessions[client_index].Reset();
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
