//+------------------------------------------------------------------+
//|                                              WebSocketClient.mqh |
//|                                     Flowsurface MT5 Data Bridge  |
//|                  WebSocket Client for connecting to Proxy Server |
//+------------------------------------------------------------------+
#property copyright "Flowsurface"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| WebSocket Client - Connects to Proxy Server                       |
//+------------------------------------------------------------------+
class CWebSocketClient
{
private:
    int    m_socket;
    bool   m_connected;
    bool   m_handshake_done;
    string m_host;
    int    m_port;
    string m_path;
    uchar  m_recv_buffer[];
    
public:
    CWebSocketClient()
    {
        m_socket = INVALID_HANDLE;
        m_connected = false;
        m_handshake_done = false;
        m_host = "";
        m_port = 9876;
        m_path = "/mt5";
    }
    
    ~CWebSocketClient()
    {
        Disconnect();
    }
    
    //--- Connection
    bool Connect(const string host, const int port, const string path = "/mt5")
    {
        m_host = host;
        m_port = port;
        m_path = path;
        
        Print("WebSocketClient: Attempting connection to ", m_host, ":", m_port, m_path);
        
        // Create socket
        m_socket = SocketCreate();
        if(m_socket == INVALID_HANDLE)
        {
            int err = GetLastError();
            Print("WebSocketClient: SocketCreate failed - Error: ", err);
            PrintSocketErrorHelp(err);
            return false;
        }
        
        Print("WebSocketClient: Socket created successfully, handle=", m_socket);
        
        // Connect to server
        Print("WebSocketClient: Calling SocketConnect(", m_host, ", ", port, ", 5000ms timeout)...");
        if(!SocketConnect(m_socket, m_host, (uint)m_port, 5000))
        {
            int err = GetLastError();
            Print("WebSocketClient: SocketConnect failed - Error: ", err);
            PrintSocketErrorHelp(err);
            SocketClose(m_socket);
            m_socket = INVALID_HANDLE;
            return false;
        }
        
        m_connected = true;
        Print("WebSocketClient: TCP connected to ", m_host, ":", m_port);
        
        // Perform WebSocket handshake
        if(!DoHandshake())
        {
            Print("WebSocketClient: Handshake failed");
            Disconnect();
            return false;
        }
        
        m_handshake_done = true;
        Print("WebSocketClient: WebSocket handshake completed");
        return true;
    }
    
    void Disconnect()
    {
        if(m_socket != INVALID_HANDLE)
        {
            // Send close frame
            if(m_handshake_done)
            {
                uchar close_frame[2];
                close_frame[0] = 0x88; // FIN + Close opcode
                close_frame[1] = 0x00; // No payload
                SocketSend(m_socket, close_frame, 2);
            }
            
            SocketClose(m_socket);
            m_socket = INVALID_HANDLE;
        }
        m_connected = false;
        m_handshake_done = false;
    }
    
    bool IsConnected() { return m_connected && m_handshake_done; }
    
    //--- Send text message
    bool SendText(const string message)
    {
        if(!IsConnected()) return false;
        
        uchar payload[];
        StringToCharArray(message, payload, 0, StringLen(message));
        
        return SendFrame(0x01, payload); // Text opcode
    }
    
    //--- Receive text message (non-blocking)
    bool ReceiveText(string &message, int timeout_ms = 100)
    {
        if(!IsConnected()) return false;
        
        // Check if socket is readable
        if(SocketIsReadable(m_socket) == 0)
            return false;
        
        uchar header[2];
        int read = SocketRead(m_socket, header, 2, (uint)timeout_ms);
        if(read != 2)
            return false;
        
        bool fin = (header[0] & 0x80) != 0;
        uchar opcode = header[0] & 0x0F;
        bool masked = (header[1] & 0x80) != 0;
        ulong payload_len = header[1] & 0x7F;
        
        // Extended payload length
        if(payload_len == 126)
        {
            uchar ext[2];
            if(SocketRead(m_socket, ext, 2, (uint)timeout_ms) != 2)
                return false;
            payload_len = (ext[0] << 8) | ext[1];
        }
        else if(payload_len == 127)
        {
            uchar ext[8];
            if(SocketRead(m_socket, ext, 8, (uint)timeout_ms) != 8)
                return false;
            payload_len = 0;
            for(int i = 0; i < 8; i++)
                payload_len = (payload_len << 8) | ext[i];
        }
        
        // Masking key (server should not send masked)
        uchar mask_key[4];
        if(masked)
        {
            if(SocketRead(m_socket, mask_key, 4, (uint)timeout_ms) != 4)
                return false;
        }
        
        // Read payload
        if(payload_len > 0)
        {
            uchar payload[];
            ArrayResize(payload, (int)payload_len);
            if(SocketRead(m_socket, payload, (uint)payload_len, 1000) != (int)payload_len)
                return false;
            
            // Unmask if needed
            if(masked)
            {
                for(int i = 0; i < (int)payload_len; i++)
                    payload[i] ^= mask_key[i % 4];
            }
            
            // Handle by opcode
            switch(opcode)
            {
                case 0x01: // Text
                    message = CharArrayToString(payload, 0, (int)payload_len);
                    return true;
                    
                case 0x08: // Close
                    Print("WebSocketClient: Server sent close frame");
                    Disconnect();
                    return false;
                    
                case 0x09: // Ping
                    SendFrame(0x0A, payload); // Pong
                    return false;
                    
                case 0x0A: // Pong
                    return false;
            }
        }
        
        return false;
    }
    
private:
    //--- WebSocket handshake
    bool DoHandshake()
    {
        Print("WebSocketClient: Starting handshake...");
        
        // Generate random key
        string ws_key = GenerateWebSocketKey();
        Print("WebSocketClient: Generated Key: ", ws_key);
        
        // Build HTTP upgrade request
        string request = "GET " + m_path + " HTTP/1.1\r\n";
        request += "Host: " + m_host + ":" + IntegerToString(m_port) + "\r\n";
        request += "Upgrade: websocket\r\n";
        request += "Connection: Upgrade\r\n";
        request += "Sec-WebSocket-Key: " + ws_key + "\r\n";
        request += "Sec-WebSocket-Version: 13\r\n";
        request += "\r\n";
        
        Print("WebSocketClient: Request Header:\n", request);
        
        // Use a simpler approach to ensure no null terminator issues
        uchar req_bytes[];
        StringToCharArray(request, req_bytes);
        // Resize to actual length of string to remove any potential null terminator added by StringToCharArray
        int str_len = StringLen(request);
        if(ArraySize(req_bytes) > str_len)
            ArrayResize(req_bytes, str_len);
            
        int send_len = ArraySize(req_bytes);
        Print("WebSocketClient: Sending ", send_len, " bytes...");
        
        if(!SocketSend(m_socket, req_bytes, send_len))
        {
            int err = GetLastError();
            Print("WebSocketClient: Failed to send handshake request - Error: ", err);
            PrintSocketErrorHelp(err);
            return false;
        }
        
        
        Print("WebSocketClient: Request sent. Waiting for response...");
        
        // Give server time to process and respond
        Sleep(500);
        
        // Check if socket is still valid
        if(m_socket == INVALID_HANDLE)
        {
            Print("WebSocketClient: Socket became invalid before reading");
            return false;
        }
        
        // Check readable bytes
        uint readable = SocketIsReadable(m_socket);
        Print("WebSocketClient: SocketIsReadable returned: ", readable);
        
        // Read response with reasonable timeout
        uchar response[];
        ArrayResize(response, 4096);
        Print("WebSocketClient: Calling SocketRead with 10s timeout...");
        int received = SocketRead(m_socket, response, 4096, 10000);
        
        Print("WebSocketClient: SocketRead returned: ", received);
        
        if(received < 0)
        {
             int err = GetLastError();
             Print("WebSocketClient: SocketRead error - Code: ", err);
             PrintSocketErrorHelp(err);
             return false;
        }
        
        if(received == 0)
        {
            Print("WebSocketClient: No handshake response (timeout)");
            return false;
        }
        
        string response_str = CharArrayToString(response, 0, received);
        Print("WebSocketClient: Received response (", received, " bytes):");
        Print(response_str);
        
        // Check for 101 Switching Protocols
        if(StringFind(response_str, "101") < 0)
        {
            Print("WebSocketClient: Invalid handshake response");
            return false;
        }
        
        return true;
    }
    
    //--- Send WebSocket frame
    bool SendFrame(uchar opcode, const uchar &payload[])
    {
        int payload_len = ArraySize(payload);
        
        // Calculate frame size (client must mask)
        int header_size = 2;
        if(payload_len > 125 && payload_len <= 65535)
            header_size += 2;
        else if(payload_len > 65535)
            header_size += 8;
        header_size += 4; // Mask key
        
        uchar frame[];
        ArrayResize(frame, header_size + payload_len);
        int pos = 0;
        
        // FIN + Opcode
        frame[pos++] = (uchar)(0x80 | opcode);
        
        // Payload length + mask bit
        if(payload_len <= 125)
        {
            frame[pos++] = (uchar)(0x80 | payload_len);
        }
        else if(payload_len <= 65535)
        {
            frame[pos++] = 0x80 | 126;
            frame[pos++] = (uchar)(payload_len >> 8);
            frame[pos++] = (uchar)(payload_len & 0xFF);
        }
        else
        {
            frame[pos++] = 0x80 | 127;
            for(int i = 7; i >= 0; i--)
                frame[pos++] = (uchar)((payload_len >> (i * 8)) & 0xFF);
        }
        
        // Generate random mask key
        uchar mask_key[4];
        for(int i = 0; i < 4; i++)
            mask_key[i] = (uchar)MathRand();
        
        frame[pos++] = mask_key[0];
        frame[pos++] = mask_key[1];
        frame[pos++] = mask_key[2];
        frame[pos++] = mask_key[3];
        
        // Masked payload
        for(int i = 0; i < payload_len; i++)
            frame[pos++] = payload[i] ^ mask_key[i % 4];
        
        return SocketSend(m_socket, frame, ArraySize(frame));
    }
    
    //--- Generate WebSocket key
    string GenerateWebSocketKey()
    {
        uchar raw[16];
        for(int i = 0; i < 16; i++)
            raw[i] = (uchar)MathRand();
        
        return Base64Encode(raw);
    }
    
    //--- Base64 encoding
    string Base64Encode(const uchar &data[])
    {
        static string chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        
        string result = "";
        int len = ArraySize(data);
        int i = 0;
        
        while(i < len)
        {
            uint a = i < len ? data[i++] : 0;
            uint b = i < len ? data[i++] : 0;
            uint c = i < len ? data[i++] : 0;
            
            uint triple = (a << 16) + (b << 8) + c;
            
            result += StringSubstr(chars, (int)((triple >> 18) & 0x3F), 1);
            result += StringSubstr(chars, (int)((triple >> 12) & 0x3F), 1);
            result += StringSubstr(chars, (int)((triple >> 6) & 0x3F), 1);
            result += StringSubstr(chars, (int)(triple & 0x3F), 1);
        }
        
        // Padding
        int mod = len % 3;
        if(mod > 0)
        {
            int pad = 3 - mod;
            for(int p = 0; p < pad; p++)
            {
                int pos = StringLen(result) - 1 - p;
                if(pos >= 0)
                    StringSetCharacter(result, pos, '=');
            }
        }
        
        return result;
    }
    
    //--- Print helpful error messages for socket errors
    void PrintSocketErrorHelp(int err)
    {
        switch(err)
        {
            case 4014:
                Print(">>> ERR_NETSOCKET_CANNOT_CONNECT: Cannot establish connection.");
                Print(">>> Possible causes:");
                Print(">>>   1. Server not running on the specified host:port");
                Print(">>>   2. Firewall blocking the connection");
                Print(">>>   3. Incorrect host/port configuration");
                Print(">>>   4. Check: Tools -> Options -> Expert Advisors -> Allow WebRequest for listed URL");
                Print(">>>   5. Try adding 'http://127.0.0.1' or 'http://localhost' to allowed URLs");
                break;
            case 4015:
                Print(">>> ERR_NETSOCKET_IO_ERROR: Socket I/O error");
                break;
            case 4016:
                Print(">>> ERR_NETSOCKET_HANDSHAKE_FAILED: Secure connection handshake failed");
                break;
            case 4017:
                Print(">>> ERR_NETSOCKET_NO_CERTIFICATE: No certificate");
                break;
            case 5273:
                Print(">>> ERR_NETSOCKET_INVALIDHANDLE: Invalid socket handle");
                break;
            case 5274:
                Print(">>> ERR_NETSOCKET_TOO_MANY_OPENED: Too many sockets opened");
                break;
            case 5275:
                Print(">>> ERR_NETSOCKET_CANNOT_CONNECT: Cannot connect to server");
                break;
            case 5276:
                Print(">>> ERR_NETSOCKET_IO_ERROR: Socket send/receive failed");
                break;
            case 5277:
                Print(">>> ERR_NETSOCKET_URL_NOT_ALLOWED: URL not allowed!");
                Print(">>> GO TO: Tools -> Options -> Expert Advisors");
                Print(">>> ADD the proxy server URL to 'Allow WebRequest for listed URL'");
                Print(">>> Example: Add 'http://127.0.0.1' or 'http://127.0.0.1:9876'");
                break;
            default:
                Print(">>> Unknown socket error: ", err);
                Print(">>> Check MQL5 documentation for error details");
                break;
        }
    }
};
