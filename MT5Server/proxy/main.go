// MT5 Proxy Server
//
// WebSocket bridge between MT5 EA and Flowsurface desktop app.
// Compiled as a single binary - no dependencies required.
//
// Usage:
//
//	mt5-proxy -port 9876 -key your_api_key -secret your_secret
package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
)

// Config holds server configuration
type Config struct {
	Port               int
	APIKey             string
	APISecret          string
	TimestampTolerance int64 // milliseconds
	HeartbeatInterval  time.Duration
	ConnectionTimeout  time.Duration
}

// Connection represents a WebSocket connection
type Connection struct {
	ID            int
	WS            *websocket.Conn
	IP            string
	Authenticated bool
	LastActivity  time.Time
	Symbols       []SymbolInfo
	Subscriptions map[string]bool
	mu            sync.Mutex
}

// SymbolInfo represents symbol metadata
type SymbolInfo struct {
	Symbol       string  `json:"symbol"`
	TickSize     float64 `json:"tick_size"`
	MinLot       float64 `json:"min_lot"`
	ContractSize float64 `json:"contract_size"`
	Digits       int     `json:"digits"`
}

// Message represents a generic JSON message
type Message map[string]interface{}

// Server is the proxy server
type Server struct {
	config           Config
	mt5Connections   map[int]*Connection
	clientConns      map[int]*Connection
	subscriptions    map[string]map[int]bool // symbol -> client IDs
	symbolData       map[string]Message
	connectionIDCtr  int
	mu               sync.RWMutex
	upgrader         websocket.Upgrader
}

var (
	config Config
	server *Server
)

func main() {
	// Parse command line flags
	flag.IntVar(&config.Port, "port", 9876, "Server port")
	flag.StringVar(&config.APIKey, "key", getEnvOrDefault("API_KEY", "your_api_key"), "API key")
	flag.StringVar(&config.APISecret, "secret", getEnvOrDefault("API_SECRET", "your_secret"), "API secret")
	flag.Int64Var(&config.TimestampTolerance, "tolerance", 30000, "Timestamp tolerance (ms)")
	flag.Parse()

	config.HeartbeatInterval = 30 * time.Second
	config.ConnectionTimeout = 60 * time.Second

	// Create server
	server = &Server{
		config:         config,
		mt5Connections: make(map[int]*Connection),
		clientConns:    make(map[int]*Connection),
		subscriptions:  make(map[string]map[int]bool),
		symbolData:     make(map[string]Message),
		upgrader: websocket.Upgrader{
			CheckOrigin: func(r *http.Request) bool { return true },
		},
	}

	// HTTP handlers
	http.HandleFunc("/mt5", server.handleMT5)
	http.HandleFunc("/client", server.handleClient)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "MT5 Proxy Server Running\n")
	})

	// Start heartbeat goroutine
	go server.heartbeatLoop()

	// Graceful shutdown
	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan
		log.Println("Shutting down...")
		server.shutdown()
		os.Exit(0)
	}()

	// Start server
	log.Println("========================================")
	log.Println("MT5 Proxy Server v1.0.0 (Go)")
	log.Println("========================================")
	log.Printf("Port: %d\n", config.Port)
	log.Printf("MT5 Endpoint: ws://localhost:%d/mt5\n", config.Port)
	log.Printf("Client Endpoint: ws://localhost:%d/client\n", config.Port)
	log.Printf("API Key: %s****\n", config.APIKey[:min(4, len(config.APIKey))])
	log.Println("========================================")

	addr := fmt.Sprintf(":%d", config.Port)
	log.Fatal(http.ListenAndServe(addr, nil))
}

func getEnvOrDefault(key, defaultVal string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return defaultVal
}

// handleMT5 handles MT5 EA WebSocket connections
func (s *Server) handleMT5(w http.ResponseWriter, r *http.Request) {
	log.Printf("[MT5] Incoming HTTP request from %s, path: %s\n", r.RemoteAddr, r.URL.Path)
	
	ws, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[MT5] Upgrade error: %v\n", err)
		return
	}

	// Set read deadline to prevent premature timeout
	// The MQL5 client needs time to complete handshake and send first message
	ws.SetReadDeadline(time.Now().Add(30 * time.Second))

	s.mu.Lock()
	s.connectionIDCtr++
	connID := s.connectionIDCtr
	conn := &Connection{
		ID:            connID,
		WS:            ws,
		IP:            r.RemoteAddr,
		Authenticated: false,
		LastActivity:  time.Now(),
		Subscriptions: make(map[string]bool),
	}
	s.mt5Connections[connID] = conn
	s.mu.Unlock()

	log.Printf("[MT5] Connection established from %s (id: %d)\n", conn.IP, connID)

	defer func() {
		ws.Close()
		s.mu.Lock()
		delete(s.mt5Connections, connID)
		s.mu.Unlock()
		log.Printf("[MT5] Disconnected (id: %d)\n", connID)
	}()

	for {
		messageType, message, err := ws.ReadMessage()
		if err != nil {
			// Log detailed error information
			log.Printf("[MT5] ReadMessage error (id: %d): %v\n", connID, err)
			break
		}
		
		// Reset read deadline on successful read
		ws.SetReadDeadline(time.Now().Add(60 * time.Second))
		
		conn.mu.Lock()
		conn.LastActivity = time.Now()
		conn.mu.Unlock()

		log.Printf("[MT5] Received message (id: %d, type: %d, len: %d)\n", connID, messageType, len(message))
		s.handleMT5Message(conn, message)
	}
}

// handleClient handles Flowsurface client WebSocket connections
func (s *Server) handleClient(w http.ResponseWriter, r *http.Request) {
	ws, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[Client] Upgrade error: %v\n", err)
		return
	}

	s.mu.Lock()
	s.connectionIDCtr++
	connID := s.connectionIDCtr
	conn := &Connection{
		ID:            connID,
		WS:            ws,
		IP:            r.RemoteAddr,
		Authenticated: false,
		LastActivity:  time.Now(),
		Subscriptions: make(map[string]bool),
	}
	s.clientConns[connID] = conn
	s.mu.Unlock()

	log.Printf("[Client] Connection from %s (id: %d)\n", conn.IP, connID)

	defer func() {
		ws.Close()
		s.mu.Lock()
		// Clean up subscriptions
		for symbol := range conn.Subscriptions {
			if subs, ok := s.subscriptions[symbol]; ok {
				delete(subs, connID)
				if len(subs) == 0 {
					delete(s.subscriptions, symbol)
				}
			}
		}
		delete(s.clientConns, connID)
		s.mu.Unlock()
		log.Printf("[Client] Disconnected (id: %d)\n", connID)
	}()

	for {
		_, message, err := ws.ReadMessage()
		if err != nil {
			break
		}
		conn.mu.Lock()
		conn.LastActivity = time.Now()
		conn.mu.Unlock()

		s.handleClientMessage(conn, message)
	}
}

// handleMT5Message processes messages from MT5 EA
func (s *Server) handleMT5Message(conn *Connection, rawMsg []byte) {
	var msg Message
	if err := json.Unmarshal(rawMsg, &msg); err != nil {
		log.Printf("[MT5] Invalid JSON from %d\n", conn.ID)
		return
	}

	msgType, _ := msg["type"].(string)

	switch msgType {
	case "auth":
		s.handleMT5Auth(conn, msg)
	case "trade", "depth", "kline":
		if conn.Authenticated {
			s.forwardMarketData(msg)
		}
	case "symbols":
		if conn.Authenticated {
			if data, ok := msg["data"].([]interface{}); ok {
				conn.Symbols = parseSymbols(data)
				log.Printf("[MT5] Symbols: %d available\n", len(conn.Symbols))
			}
		}
	case "klines":
		if conn.Authenticated {
			s.forwardKlinesResponse(msg)
		}
	case "ping":
		s.sendTo(conn.WS, Message{"type": "pong", "time": time.Now().UnixMilli()})
	default:
		if !conn.Authenticated {
			s.sendTo(conn.WS, Message{"type": "error", "message": "Not authenticated"})
		}
	}
}

// handleClientMessage processes messages from Flowsurface clients
func (s *Server) handleClientMessage(conn *Connection, rawMsg []byte) {
	var msg Message
	if err := json.Unmarshal(rawMsg, &msg); err != nil {
		log.Printf("[Client] Invalid JSON from %d\n", conn.ID)
		return
	}

	msgType, _ := msg["type"].(string)

	switch msgType {
	case "auth":
		s.handleClientAuth(conn, msg)
	case "subscribe":
		if conn.Authenticated {
			s.handleSubscribe(conn, msg)
		}
	case "unsubscribe":
		if conn.Authenticated {
			s.handleUnsubscribe(conn, msg)
		}
	case "get_symbols":
		if conn.Authenticated {
			s.handleGetSymbols(conn)
		}
	case "get_klines":
		if conn.Authenticated {
			s.handleGetKlines(conn, msg)
		}
	case "ping":
		s.sendTo(conn.WS, Message{"type": "pong", "time": time.Now().UnixMilli()})
	default:
		if !conn.Authenticated {
			s.sendTo(conn.WS, Message{"type": "error", "message": "Not authenticated"})
		}
	}
}

// handleMT5Auth authenticates MT5 connection
func (s *Server) handleMT5Auth(conn *Connection, msg Message) {
	apiKey, _ := msg["api_key"].(string)
	timestamp, _ := msg["timestamp"].(float64)
	signature, _ := msg["signature"].(string)

	result := s.validateAuth(apiKey, int64(timestamp), signature)

	if result {
		conn.Authenticated = true
		log.Printf("[MT5] Authenticated (id: %d)\n", conn.ID)
		s.sendTo(conn.WS, Message{
			"type":        "auth_response",
			"success":     true,
			"server_time": time.Now().UnixMilli(),
		})
	} else {
		log.Printf("[MT5] Auth failed (id: %d)\n", conn.ID)
		s.sendTo(conn.WS, Message{
			"type":    "auth_response",
			"success": false,
			"error":   "Authentication failed",
		})
	}
}

// handleClientAuth authenticates Flowsurface client
func (s *Server) handleClientAuth(conn *Connection, msg Message) {
	apiKey, _ := msg["api_key"].(string)
	timestamp, _ := msg["timestamp"].(float64)
	signature, _ := msg["signature"].(string)

	result := s.validateAuth(apiKey, int64(timestamp), signature)

	if result {
		conn.Authenticated = true
		log.Printf("[Client] Authenticated (id: %d)\n", conn.ID)
		s.sendTo(conn.WS, Message{
			"type":        "auth_response",
			"success":     true,
			"server_time": time.Now().UnixMilli(),
		})
	} else {
		log.Printf("[Client] Auth failed (id: %d)\n", conn.ID)
		s.sendTo(conn.WS, Message{
			"type":    "auth_response",
			"success": false,
			"error":   "Authentication failed",
		})
	}
}

// validateAuth validates API key and signature
func (s *Server) validateAuth(apiKey string, timestamp int64, signature string) bool {
	if apiKey != s.config.APIKey {
		log.Printf("[Auth] API Key mismatch: received '%s', expected '%s'\n", apiKey, s.config.APIKey)
		return false
	}

	now := time.Now().UnixMilli()
	diff := now - timestamp
	if diff < 0 {
		diff = -diff
	}
	if diff > s.config.TimestampTolerance {
		log.Printf("[Auth] Timestamp expired: server=%d, client=%d, diff=%dms, tolerance=%dms\n", 
			now, timestamp, diff, s.config.TimestampTolerance)
		return false
	}

	expected := s.computeSignature(apiKey, timestamp)
	if signature != expected {
		log.Printf("[Auth] Signature mismatch: received '%s', expected '%s'\n", signature, expected)
		return false
	}
	
	return true
}

// computeSignature computes HMAC-SHA256 signature
func (s *Server) computeSignature(apiKey string, timestamp int64) string {
	message := fmt.Sprintf("%s%d", apiKey, timestamp)
	mac := hmac.New(sha256.New, []byte(s.config.APISecret))
	mac.Write([]byte(message))
	return hex.EncodeToString(mac.Sum(nil))
}

// handleSubscribe handles subscription request
func (s *Server) handleSubscribe(conn *Connection, msg Message) {
	symbols, _ := msg["symbols"].([]interface{})

	s.mu.Lock()
	for _, sym := range symbols {
		symbol, _ := sym.(string)
		if symbol == "" {
			continue
		}
		conn.Subscriptions[symbol] = true
		if s.subscriptions[symbol] == nil {
			s.subscriptions[symbol] = make(map[int]bool)
		}
		s.subscriptions[symbol][conn.ID] = true
	}
	s.mu.Unlock()

	log.Printf("[Client] %d subscribed to %d symbols\n", conn.ID, len(symbols))

	s.sendTo(conn.WS, Message{
		"type":    "subscribed",
		"symbols": symbols,
	})
}

// handleUnsubscribe handles unsubscription request
func (s *Server) handleUnsubscribe(conn *Connection, msg Message) {
	symbols, _ := msg["symbols"].([]interface{})
	if len(symbols) == 0 {
		// Unsubscribe from all
		for sym := range conn.Subscriptions {
			symbols = append(symbols, sym)
		}
	}

	s.mu.Lock()
	for _, sym := range symbols {
		symbol, _ := sym.(string)
		delete(conn.Subscriptions, symbol)
		if subs, ok := s.subscriptions[symbol]; ok {
			delete(subs, conn.ID)
			if len(subs) == 0 {
				delete(s.subscriptions, symbol)
			}
		}
	}
	s.mu.Unlock()

	s.sendTo(conn.WS, Message{"type": "unsubscribed", "symbols": symbols})
}

// handleGetSymbols sends available symbols to client
func (s *Server) handleGetSymbols(conn *Connection) {
	var allSymbols []SymbolInfo

	s.mu.RLock()
	for _, mt5Conn := range s.mt5Connections {
		if mt5Conn.Authenticated {
			allSymbols = append(allSymbols, mt5Conn.Symbols...)
		}
	}
	s.mu.RUnlock()

	s.sendTo(conn.WS, Message{
		"type": "symbols",
		"data": allSymbols,
	})
}

// handleGetKlines forwards klines request to MT5
func (s *Server) handleGetKlines(conn *Connection, msg Message) {
	s.mu.RLock()
	var mt5Conn *Connection
	for _, c := range s.mt5Connections {
		if c.Authenticated {
			mt5Conn = c
			break
		}
	}
	s.mu.RUnlock()

	if mt5Conn == nil {
		s.sendTo(conn.WS, Message{
			"type":    "error",
			"message": "No MT5 connection available",
		})
		return
	}

	msg["request_id"] = float64(conn.ID)
	s.sendTo(mt5Conn.WS, msg)
}

// forwardMarketData forwards market data to subscribed clients
func (s *Server) forwardMarketData(msg Message) {
	symbol, _ := msg["symbol"].(string)
	if symbol == "" {
		return
	}

	s.mu.Lock()
	s.symbolData[symbol] = msg
	subscribers := s.subscriptions[symbol]
	s.mu.Unlock()

	if subscribers == nil {
		return
	}

	data, _ := json.Marshal(msg)

	s.mu.RLock()
	for clientID := range subscribers {
		if client, ok := s.clientConns[clientID]; ok && client.Authenticated {
			client.WS.WriteMessage(websocket.TextMessage, data)
		}
	}
	s.mu.RUnlock()
}

// forwardKlinesResponse forwards klines response to requesting client
func (s *Server) forwardKlinesResponse(msg Message) {
	requestID, ok := msg["request_id"].(float64)
	if !ok {
		return
	}

	s.mu.RLock()
	client, ok := s.clientConns[int(requestID)]
	s.mu.RUnlock()

	if ok && client.Authenticated {
		delete(msg, "request_id")
		s.sendTo(client.WS, msg)
	}
}

// sendTo sends a JSON message to a WebSocket
func (s *Server) sendTo(ws *websocket.Conn, msg Message) {
	data, err := json.Marshal(msg)
	if err != nil {
		return
	}
	ws.WriteMessage(websocket.TextMessage, data)
}

// heartbeatLoop sends periodic heartbeats and cleans up stale connections
func (s *Server) heartbeatLoop() {
	ticker := time.NewTicker(s.config.HeartbeatInterval)
	for range ticker.C {
		now := time.Now()
		heartbeat := Message{"type": "heartbeat", "time": now.UnixMilli()}

		s.mu.Lock()
		// Check MT5 connections
		for id, conn := range s.mt5Connections {
			if now.Sub(conn.LastActivity) > s.config.ConnectionTimeout {
				log.Printf("[MT5] Timeout (id: %d)\n", id)
				conn.WS.Close()
				delete(s.mt5Connections, id)
			} else if conn.Authenticated {
				s.sendTo(conn.WS, heartbeat)
			}
		}

		// Check client connections
		for id, conn := range s.clientConns {
			if now.Sub(conn.LastActivity) > s.config.ConnectionTimeout {
				log.Printf("[Client] Timeout (id: %d)\n", id)
				conn.WS.Close()
				delete(s.clientConns, id)
			} else if conn.Authenticated {
				s.sendTo(conn.WS, heartbeat)
			}
		}
		s.mu.Unlock()
	}
}

// shutdown closes all connections
func (s *Server) shutdown() {
	s.mu.Lock()
	defer s.mu.Unlock()

	for _, conn := range s.mt5Connections {
		conn.WS.Close()
	}
	for _, conn := range s.clientConns {
		conn.WS.Close()
	}
}

// parseSymbols parses symbol info from JSON array
func parseSymbols(data []interface{}) []SymbolInfo {
	var symbols []SymbolInfo
	for _, item := range data {
		if m, ok := item.(map[string]interface{}); ok {
			sym := SymbolInfo{
				Symbol:       getString(m, "symbol"),
				TickSize:     getFloat(m, "tick_size"),
				MinLot:       getFloat(m, "min_lot"),
				ContractSize: getFloat(m, "contract_size"),
				Digits:       int(getFloat(m, "digits")),
			}
			symbols = append(symbols, sym)
		}
	}
	return symbols
}

func getString(m map[string]interface{}, key string) string {
	if v, ok := m[key].(string); ok {
		return v
	}
	return ""
}

func getFloat(m map[string]interface{}, key string) float64 {
	if v, ok := m[key].(float64); ok {
		return v
	}
	return 0
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func init() {
	// Suppress unused import warning
	_ = math.MaxInt
}
