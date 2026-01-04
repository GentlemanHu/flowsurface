//+------------------------------------------------------------------+
//|                                              WebSocketServer.mqh |
//|                                     Flowsurface MT5 Data Bridge  |
//|                  WebSocket Server Implementation using WinSocket |
//+------------------------------------------------------------------+
#property copyright "Flowsurface"
#property version   "1.00"
#property strict

#include <WinAPI\WinAPI.mqh>

//+------------------------------------------------------------------+
//| WebSocket Frame Opcodes                                           |
//+------------------------------------------------------------------+
#define WS_OPCODE_CONTINUATION 0x00
#define WS_OPCODE_TEXT         0x01
#define WS_OPCODE_BINARY       0x02
#define WS_OPCODE_CLOSE        0x08
#define WS_OPCODE_PING         0x09
#define WS_OPCODE_PONG         0x0A

//+------------------------------------------------------------------+
//| WebSocket Frame Structure                                         |
//+------------------------------------------------------------------+
struct WebSocketFrame
{
    bool   fin;
    uchar  opcode;
    bool   masked;
    ulong  payload_len;
    uchar  mask_key[4];
    uchar  payload[];
};

//+------------------------------------------------------------------+
//| TCP Socket Wrapper for MQL5                                       |
//+------------------------------------------------------------------+
class CTcpSocket
{
private:
    int m_socket;
    bool m_connected;
    
public:
    CTcpSocket() : m_socket(INVALID_HANDLE), m_connected(false) {}
    
    ~CTcpSocket()
    {
        Close();
    }
    
    bool Create()
    {
        m_socket = SocketCreate();
        if(m_socket == INVALID_HANDLE)
        {
            Print("SocketCreate failed: ", GetLastError());
            return false;
        }
        return true;
    }
    
    bool Bind(const string address, const int port)
    {
        if(m_socket == INVALID_HANDLE) return false;
        
        // For MQL5, we use SocketConnect as server-like functionality
        // Note: MQL5 doesn't have native server socket, we'll use polling
        return true;
    }
    
    bool Listen(int backlog = 5)
    {
        // MQL5 limitation: No native listen support
        // We simulate server behavior differently
        return true;
    }
    
    int Accept()
    {
        // MQL5 limitation: Direct accept not available
        // Use external DLL or alternative approach
        return INVALID_HANDLE;
    }
    
    int Send(const uchar &data[], int size = -1)
    {
        if(m_socket == INVALID_HANDLE) return -1;
        
        int sendSize = (size < 0) ? ArraySize(data) : size;
        if(!SocketSend(m_socket, data, (uint)sendSize))
        {
            Print("SocketSend failed: ", GetLastError());
            return -1;
        }
        return sendSize;
    }
    
    int Receive(uchar &buffer[], int maxSize, int timeout_ms = 1000)
    {
        if(m_socket == INVALID_HANDLE) return -1;
        
        ArrayResize(buffer, maxSize);
        uint received = SocketRead(m_socket, buffer, (uint)maxSize, (uint)timeout_ms);
        
        if(received == 0 && GetLastError() != 0)
        {
            return -1;
        }
        
        ArrayResize(buffer, (int)received);
        return (int)received;
    }
    
    bool IsReadable(int timeout_ms = 0)
    {
        if(m_socket == INVALID_HANDLE) return false;
        return SocketIsReadable(m_socket) > 0;
    }
    
    bool IsWritable(int timeout_ms = 0)
    {
        if(m_socket == INVALID_HANDLE) return false;
        return SocketIsWritable(m_socket);
    }
    
    void Close()
    {
        if(m_socket != INVALID_HANDLE)
        {
            SocketClose(m_socket);
            m_socket = INVALID_HANDLE;
        }
        m_connected = false;
    }
    
    int Handle() { return m_socket; }
    bool IsConnected() { return m_connected; }
};

//+------------------------------------------------------------------+
//| WebSocket Connection (single client)                              |
//+------------------------------------------------------------------+
class CWebSocketConnection
{
private:
    int    m_socket;
    bool   m_handshake_done;
    string m_client_ip;
    uchar  m_recv_buffer[];
    int    m_recv_buffer_pos;
    
public:
    CWebSocketConnection()
    {
        Reset();
    }
    
    void Reset()
    {
        m_socket = INVALID_HANDLE;
        m_handshake_done = false;
        m_client_ip = "";
        ArrayResize(m_recv_buffer, 0);
        m_recv_buffer_pos = 0;
    }
    
    void SetSocket(int socket, const string ip = "")
    {
        m_socket = socket;
        m_client_ip = ip;
        m_handshake_done = false;
    }
    
    int Socket() { return m_socket; }
    string ClientIP() { return m_client_ip; }
    bool IsConnected() { return m_socket != INVALID_HANDLE; }
    bool HandshakeDone() { return m_handshake_done; }
    
    //--- WebSocket Handshake
    bool ProcessHandshake(const uchar &request[])
    {
        string req_str = CharArrayToString(request, 0, ArraySize(request));
        
        // Parse HTTP upgrade request
        if(StringFind(req_str, "Upgrade: websocket") < 0)
        {
            Print("Not a WebSocket upgrade request");
            return false;
        }
        
        // Extract Sec-WebSocket-Key
        string ws_key = "";
        int key_start = StringFind(req_str, "Sec-WebSocket-Key: ");
        if(key_start >= 0)
        {
            key_start += 19; // Length of "Sec-WebSocket-Key: "
            int key_end = StringFind(req_str, "\r\n", key_start);
            if(key_end > key_start)
            {
                ws_key = StringSubstr(req_str, key_start, key_end - key_start);
            }
        }
        
        if(ws_key == "")
        {
            Print("Missing Sec-WebSocket-Key");
            return false;
        }
        
        // Compute accept key
        string accept_key = ComputeAcceptKey(ws_key);
        
        // Send handshake response
        string response = "HTTP/1.1 101 Switching Protocols\r\n";
        response += "Upgrade: websocket\r\n";
        response += "Connection: Upgrade\r\n";
        response += "Sec-WebSocket-Accept: " + accept_key + "\r\n";
        response += "\r\n";
        
        uchar response_bytes[];
        StringToCharArray(response, response_bytes, 0, StringLen(response));
        
        if(SocketSend(m_socket, response_bytes, (uint)StringLen(response)))
        {
            m_handshake_done = true;
            return true;
        }
        
        return false;
    }
    
    //--- Send WebSocket Frame
    bool SendText(const string message)
    {
        if(!m_handshake_done) return false;
        
        uchar payload[];
        StringToCharArray(message, payload, 0, StringLen(message));
        
        return SendFrame(WS_OPCODE_TEXT, payload);
    }
    
    bool SendFrame(uchar opcode, const uchar &payload[])
    {
        int payload_len = ArraySize(payload);
        uchar frame[];
        
        // Calculate frame size
        int header_size = 2;
        if(payload_len > 125 && payload_len <= 65535)
            header_size += 2;
        else if(payload_len > 65535)
            header_size += 8;
        
        ArrayResize(frame, header_size + payload_len);
        
        // FIN + Opcode
        frame[0] = (uchar)(0x80 | opcode);
        
        // Payload length
        if(payload_len <= 125)
        {
            frame[1] = (uchar)payload_len;
        }
        else if(payload_len <= 65535)
        {
            frame[1] = 126;
            frame[2] = (uchar)(payload_len >> 8);
            frame[3] = (uchar)(payload_len & 0xFF);
        }
        else
        {
            frame[1] = 127;
            for(int i = 0; i < 8; i++)
            {
                frame[2 + i] = (uchar)((payload_len >> (56 - i * 8)) & 0xFF);
            }
        }
        
        // Copy payload
        ArrayCopy(frame, payload, header_size);
        
        return SocketSend(m_socket, frame, (uint)ArraySize(frame));
    }
    
    //--- Receive WebSocket Frame
    bool ReceiveFrame(WebSocketFrame &frame)
    {
        uchar header[2];
        
        if(SocketRead(m_socket, header, 2, 100) != 2)
            return false;
        
        frame.fin = (header[0] & 0x80) != 0;
        frame.opcode = header[0] & 0x0F;
        frame.masked = (header[1] & 0x80) != 0;
        frame.payload_len = header[1] & 0x7F;
        
        // Extended payload length
        if(frame.payload_len == 126)
        {
            uchar ext[2];
            if(SocketRead(m_socket, ext, 2, 100) != 2)
                return false;
            frame.payload_len = (ext[0] << 8) | ext[1];
        }
        else if(frame.payload_len == 127)
        {
            uchar ext[8];
            if(SocketRead(m_socket, ext, 8, 100) != 8)
                return false;
            frame.payload_len = 0;
            for(int i = 0; i < 8; i++)
            {
                frame.payload_len = (frame.payload_len << 8) | ext[i];
            }
        }
        
        // Masking key
        if(frame.masked)
        {
            if(SocketRead(m_socket, frame.mask_key, 4, 100) != 4)
                return false;
        }
        
        // Payload
        if(frame.payload_len > 0)
        {
            ArrayResize(frame.payload, (int)frame.payload_len);
            if(SocketRead(m_socket, frame.payload, (uint)frame.payload_len, 1000) != (int)frame.payload_len)
                return false;
            
            // Unmask if needed
            if(frame.masked)
            {
                for(int i = 0; i < (int)frame.payload_len; i++)
                {
                    frame.payload[i] ^= frame.mask_key[i % 4];
                }
            }
        }
        
        return true;
    }
    
    void Close()
    {
        if(m_socket != INVALID_HANDLE)
        {
            // Send close frame
            uchar empty[];
            SendFrame(WS_OPCODE_CLOSE, empty);
            
            SocketClose(m_socket);
            m_socket = INVALID_HANDLE;
        }
        m_handshake_done = false;
    }

private:
    string ComputeAcceptKey(const string key)
    {
        // WebSocket magic GUID
        string magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        string combined = key + magic;
        
        // SHA-1 hash
        uchar data[];
        uchar hash[];
        StringToCharArray(combined, data, 0, StringLen(combined));
        
        if(CryptEncode(CRYPT_HASH_SHA1, data, hash, hash))
        {
            // Base64 encode
            return Base64Encode(hash);
        }
        
        return "";
    }
    
    string Base64Encode(const uchar &data[])
    {
        static string base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        
        string result = "";
        int len = ArraySize(data);
        int i = 0;
        
        while(i < len)
        {
            uint octet_a = i < len ? data[i++] : 0;
            uint octet_b = i < len ? data[i++] : 0;
            uint octet_c = i < len ? data[i++] : 0;
            
            uint triple = (octet_a << 16) + (octet_b << 8) + octet_c;
            
            result += StringSubstr(base64_chars, (int)((triple >> 18) & 0x3F), 1);
            result += StringSubstr(base64_chars, (int)((triple >> 12) & 0x3F), 1);
            result += StringSubstr(base64_chars, (int)((triple >> 6) & 0x3F), 1);
            result += StringSubstr(base64_chars, (int)(triple & 0x3F), 1);
        }
        
        // Padding
        int mod = len % 3;
        if(mod > 0)
        {
            int pad_count = 3 - mod;
            for(int p = 0; p < pad_count; p++)
            {
                int pos = StringLen(result) - 1 - p;
                if(pos >= 0)
                    StringSetCharacter(result, pos, '=');
            }
        }
        
        return result;
    }
};

//+------------------------------------------------------------------+
//| Simple WebSocket Server (using external connection)               |
//| Note: MQL5 lacks native server socket. This uses SocketConnect   |
//| as a workaround for client connections via reverse proxy/tunnel  |
//+------------------------------------------------------------------+
class CWebSocketServer
{
private:
    int    m_port;
    bool   m_running;
    CWebSocketConnection m_clients[];
    int    m_max_clients;
    
public:
    CWebSocketServer() : m_port(9876), m_running(false), m_max_clients(10)
    {
        ArrayResize(m_clients, m_max_clients);
    }
    
    bool Start(int port)
    {
        m_port = port;
        m_running = true;
        
        Print("WebSocket Server starting on port ", port);
        Print("Note: MQL5 requires external TCP listener. See documentation.");
        
        return true;
    }
    
    void Stop()
    {
        m_running = false;
        
        // Close all client connections
        for(int i = 0; i < ArraySize(m_clients); i++)
        {
            if(m_clients[i].IsConnected())
            {
                m_clients[i].Close();
            }
        }
        
        Print("WebSocket Server stopped");
    }
    
    bool IsRunning() { return m_running; }
    int Port() { return m_port; }
    
    //--- Client management
    int AddClient(int socket, const string ip = "")
    {
        for(int i = 0; i < ArraySize(m_clients); i++)
        {
            if(!m_clients[i].IsConnected())
            {
                m_clients[i].SetSocket(socket, ip);
                Print("Client connected: slot ", i, ", IP: ", ip);
                return i;
            }
        }
        return -1; // No available slot
    }
    
    CWebSocketConnection* GetClient(int index)
    {
        if(index >= 0 && index < ArraySize(m_clients))
            return GetPointer(m_clients[index]);
        return NULL;
    }
    
    void RemoveClient(int index)
    {
        if(index >= 0 && index < ArraySize(m_clients))
        {
            m_clients[index].Close();
            m_clients[index].Reset();
            Print("Client disconnected: slot ", index);
        }
    }
    
    //--- Broadcast to all authenticated clients
    void Broadcast(const string message)
    {
        for(int i = 0; i < ArraySize(m_clients); i++)
        {
            if(m_clients[i].IsConnected() && m_clients[i].HandshakeDone())
            {
                m_clients[i].SendText(message);
            }
        }
    }
    
    int GetConnectedCount()
    {
        int count = 0;
        for(int i = 0; i < ArraySize(m_clients); i++)
        {
            if(m_clients[i].IsConnected())
                count++;
        }
        return count;
    }
};
