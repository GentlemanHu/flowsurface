//+------------------------------------------------------------------+
//|                                               Authentication.mqh |
//|                                     Flowsurface MT5 Data Bridge  |
//|                           API Key + HMAC-SHA256 Authentication   |
//+------------------------------------------------------------------+
#property copyright "Flowsurface"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Authentication Manager                                            |
//+------------------------------------------------------------------+
class CAuthManager
{
private:
    string m_api_key;
    string m_api_secret;
    long   m_timestamp_tolerance_ms;  // Max allowed time difference
    string m_allowed_ips[];           // IP whitelist (empty = allow all)
    
public:
    CAuthManager()
    {
        m_api_key = "";
        m_api_secret = "";
        m_timestamp_tolerance_ms = 30000; // 30 seconds
    }
    
    //--- Configuration
    void SetCredentials(const string api_key, const string api_secret)
    {
        m_api_key = api_key;
        m_api_secret = api_secret;
    }
    
    void SetTimestampTolerance(const long tolerance_ms)
    {
        m_timestamp_tolerance_ms = tolerance_ms;
    }
    
    void AddAllowedIP(const string ip)
    {
        int size = ArraySize(m_allowed_ips);
        ArrayResize(m_allowed_ips, size + 1);
        m_allowed_ips[size] = ip;
    }
    
    void ClearAllowedIPs()
    {
        ArrayResize(m_allowed_ips, 0);
    }
    
    //--- Validation
    bool ValidateAuth(const string received_key, const long timestamp, 
                      const string signature, const string client_ip,
                      string &error_msg)
    {
        // 1. Check if credentials are configured
        if(m_api_key == "" || m_api_secret == "")
        {
            error_msg = "Server credentials not configured";
            return false;
        }
        
        // 2. Validate API Key
        if(received_key != m_api_key)
        {
            error_msg = "Invalid API key";
            return false;
        }
        
        // 3. Check timestamp (replay attack prevention)
        long server_time = GetCurrentTimestampMs();
        long time_diff = MathAbs(server_time - timestamp);
        
        if(time_diff > m_timestamp_tolerance_ms)
        {
            error_msg = StringFormat("Timestamp expired. Server: %I64d, Client: %I64d, Diff: %I64d ms",
                                     server_time, timestamp, time_diff);
            return false;
        }
        
        // 4. Validate HMAC signature
        string expected_signature = ComputeSignature(received_key, timestamp);
        if(signature != expected_signature)
        {
            error_msg = "Invalid signature";
            return false;
        }
        
        // 5. Check IP whitelist (if configured)
        if(ArraySize(m_allowed_ips) > 0)
        {
            bool ip_allowed = false;
            for(int i = 0; i < ArraySize(m_allowed_ips); i++)
            {
                if(m_allowed_ips[i] == client_ip || m_allowed_ips[i] == "*")
                {
                    ip_allowed = true;
                    break;
                }
            }
            if(!ip_allowed)
            {
                error_msg = "IP not in whitelist: " + client_ip;
                return false;
            }
        }
        
        error_msg = "";
        return true;
    }
    
    //--- Signature computation (for testing/debug)
    string ComputeSignature(const string api_key, const long timestamp)
    {
        string message = api_key + IntegerToString(timestamp);
        return HMAC_SHA256(message, m_api_secret);
    }
    
    long GetCurrentTimestampMs()
    {
        return (long)TimeCurrent() * 1000 + GetTickCount() % 1000;
    }

private:
    //--- HMAC-SHA256 Implementation (RFC 2104)
    string HMAC_SHA256(const string message, const string key)
    {
        const int BLOCK_SIZE = 64;  // SHA256 block size
        
        // Convert strings to byte arrays
        uchar key_bytes[];
        uchar message_bytes[];
        StringToCharArray(key, key_bytes, 0, StringLen(key));
        StringToCharArray(message, message_bytes, 0, StringLen(message));
        
        // If key is longer than block size, hash it first
        if(ArraySize(key_bytes) > BLOCK_SIZE)
        {
            uchar hashed_key[];
            uchar dummy[];
            CryptEncode(CRYPT_HASH_SHA256, key_bytes, dummy, hashed_key);
            ArrayCopy(key_bytes, hashed_key);
            ArrayResize(key_bytes, ArraySize(hashed_key));
        }
        
        // Pad key to block size
        if(ArraySize(key_bytes) < BLOCK_SIZE)
        {
            int old_size = ArraySize(key_bytes);
            ArrayResize(key_bytes, BLOCK_SIZE);
            for(int i = old_size; i < BLOCK_SIZE; i++)
                key_bytes[i] = 0x00;
        }
        
        // Create inner and outer key pads
        uchar i_key_pad[];
        uchar o_key_pad[];
        ArrayResize(i_key_pad, BLOCK_SIZE);
        ArrayResize(o_key_pad, BLOCK_SIZE);
        
        for(int i = 0; i < BLOCK_SIZE; i++)
        {
            i_key_pad[i] = key_bytes[i] ^ 0x36;
            o_key_pad[i] = key_bytes[i] ^ 0x5C;
        }
        
        // Inner hash: SHA256(i_key_pad + message)
        uchar inner_data[];
        ArrayResize(inner_data, BLOCK_SIZE + ArraySize(message_bytes));
        ArrayCopy(inner_data, i_key_pad, 0, 0, BLOCK_SIZE);
        ArrayCopy(inner_data, message_bytes, BLOCK_SIZE, 0, ArraySize(message_bytes));
        
        uchar inner_hash[];
        uchar dummy[];
        CryptEncode(CRYPT_HASH_SHA256, inner_data, dummy, inner_hash);
        
        // Outer hash: SHA256(o_key_pad + inner_hash)
        uchar outer_data[];
        ArrayResize(outer_data, BLOCK_SIZE + ArraySize(inner_hash));
        ArrayCopy(outer_data, o_key_pad, 0, 0, BLOCK_SIZE);
        ArrayCopy(outer_data, inner_hash, BLOCK_SIZE, 0, ArraySize(inner_hash));
        
        uchar result[];
        CryptEncode(CRYPT_HASH_SHA256, outer_data, dummy, result);
        
        return ArrayToHex(result);
    }
    
    string ArrayToHex(const uchar &arr[])
    {
        string result = "";
        int size = ArraySize(arr);
        for(int i = 0; i < size; i++)
        {
            result += StringFormat("%02x", arr[i]);
        }
        return result;
    }
    
    string SimpleHash(const string str)
    {
        // Simple hash for fallback (not cryptographically secure)
        ulong hash = 5381;
        int len = StringLen(str);
        for(int i = 0; i < len; i++)
        {
            hash = ((hash << 5) + hash) + StringGetCharacter(str, i);
        }
        return StringFormat("%016llX", hash);
    }
};

//+------------------------------------------------------------------+
//| Client Session - Tracks authenticated client state                |
//+------------------------------------------------------------------+
class CClientSession
{
public:
    int    socket_handle;
    string client_ip;
    bool   is_authenticated;
    long   auth_time;
    long   last_activity;
    string subscribed_symbols[];
    bool   subscribe_depth;
    bool   subscribe_trades;
    bool   subscribe_klines;
    
    CClientSession()
    {
        Reset();
    }
    
    void Reset()
    {
        socket_handle = INVALID_HANDLE;
        client_ip = "";
        is_authenticated = false;
        auth_time = 0;
        last_activity = 0;
        ArrayResize(subscribed_symbols, 0);
        subscribe_depth = false;
        subscribe_trades = false;
        subscribe_klines = false;
    }
    
    bool IsSubscribed(const string symbol)
    {
        for(int i = 0; i < ArraySize(subscribed_symbols); i++)
        {
            if(subscribed_symbols[i] == symbol) return true;
        }
        return false;
    }
    
    void AddSubscription(const string symbol)
    {
        if(!IsSubscribed(symbol))
        {
            int size = ArraySize(subscribed_symbols);
            ArrayResize(subscribed_symbols, size + 1);
            subscribed_symbols[size] = symbol;
        }
    }
    
    void UpdateActivity()
    {
        last_activity = (long)TimeCurrent() * 1000;
    }
    
    bool IsExpired(long timeout_ms)
    {
        long now = (long)TimeCurrent() * 1000;
        return (now - last_activity) > timeout_ms;
    }
};
