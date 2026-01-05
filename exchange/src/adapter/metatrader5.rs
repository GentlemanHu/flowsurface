//! MetaTrader 5 WebSocket adapter for Flowsurface
//!
//! Connects to a Go proxy server which bridges MT5 EA data.
//!
//! # Architecture
//!
//! ```text
//! MT5 Terminal + FlowsurfaceServer.mq5
//!              |
//!              | WebSocket (JSON)
//!              v
//! Go Proxy Server (mt5-proxy)
//!              |
//!              | WebSocket (JSON)
//!              v
//! Flowsurface Desktop (this adapter)
//! ```
//!
//! # Security
//!
//! - API Key + HMAC-SHA256 signature authentication
//! - Optional TLS encryption
//! - Timestamp-based replay attack prevention

use super::{AdapterError, Event, StreamKind, StreamTicksize};
use crate::{
    depth::{DepthPayload, DepthUpdate, LocalDepthCache},
    Kline, Price, PushFrequency, Ticker, TickerInfo, TickerStats, Timeframe, Trade,
};

use iced_futures::{
    futures::{channel::mpsc, SinkExt, Stream},
    stream,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, sync::Arc, time::Duration};

// ============================================================================
// Configuration Types
// ============================================================================

/// MT5 server connection configuration
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Mt5Config {
    /// Server address (e.g., "192.168.1.100:9876" or "localhost:9876")
    pub server_addr: String,
    /// API Key for authentication
    pub api_key: String,
    /// API Secret for HMAC signature (not serialized for security)
    #[serde(skip_serializing, default)]
    pub api_secret: String,
    /// Whether to use TLS (wss://)
    #[serde(default)]
    pub use_tls: bool,
    /// Connection timeout in seconds
    #[serde(default = "default_timeout")]
    pub timeout_secs: u64,
    /// Auto-reconnect on disconnect
    #[serde(default = "default_true")]
    pub auto_reconnect: bool,
}

fn default_timeout() -> u64 {
    30
}

fn default_true() -> bool {
    true
}

impl Default for Mt5Config {
    fn default() -> Self {
        Self {
            server_addr: "localhost:9876".to_string(),
            api_key: String::new(),
            api_secret: String::new(),
            use_tls: false,
            timeout_secs: 30,
            auto_reconnect: true,
        }
    }
}

impl Mt5Config {
    /// Create WebSocket URL from config (for client endpoint)
    pub fn ws_url(&self) -> String {
        let protocol = if self.use_tls { "wss" } else { "ws" };
        format!("{}://{}/client", protocol, self.server_addr)
    }

    /// Validate configuration
    pub fn validate(&self) -> Result<(), String> {
        if self.server_addr.is_empty() {
            return Err("Server address is required".to_string());
        }
        if self.api_key.is_empty() {
            return Err("API key is required".to_string());
        }
        if self.api_secret.is_empty() {
            return Err("API secret is required".to_string());
        }
        Ok(())
    }

    /// Test connection to proxy server
    pub async fn test_connection(&self) -> Result<(), String> {
        use tokio_tungstenite::tungstenite::Message;

        // Validate config first
        self.validate()?;

        let url = self.ws_url();
        log::info!("Testing connection to {}", url);

        // Try to connect
        let connect_result = tokio::time::timeout(
            Duration::from_secs(self.timeout_secs),
            tokio_tungstenite::connect_async(&url),
        )
        .await
        .map_err(|_| "Connection timeout".to_string())?
        .map_err(|e| format!("WebSocket error: {}", e))?;

        let (mut ws, _response) = connect_result;

        // Send auth message
        let timestamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;

        let signature = compute_hmac_signature(&self.api_key, timestamp, &self.api_secret);

        let auth_msg = serde_json::json!({
            "type": "auth",
            "api_key": self.api_key,
            "timestamp": timestamp,
            "signature": signature
        });

        use futures_util::SinkExt as _;
        ws.send(Message::Text(auth_msg.to_string()))
            .await
            .map_err(|e| format!("Failed to send auth: {}", e))?;

        // Wait for auth response
        use futures_util::StreamExt as _;
        let response = tokio::time::timeout(Duration::from_secs(10), ws.next())
            .await
            .map_err(|_| "Auth response timeout".to_string())?
            .ok_or("Connection closed")?
            .map_err(|e| format!("Read error: {}", e))?;

        if let Message::Text(text) = response {
            let resp: serde_json::Value =
                serde_json::from_str(&text).map_err(|e| format!("Invalid JSON: {}", e))?;

            if resp["type"] == "auth_response" {
                if resp["success"] == true {
                    log::info!("Connection test successful");
                    return Ok(());
                } else {
                    let error = resp["error"].as_str().unwrap_or("Unknown error");
                    return Err(format!("Auth failed: {}", error));
                }
            }
        }

        Err("Invalid auth response".to_string())
    }
}

// ============================================================================
// Message Types (JSON Protocol)
// ============================================================================

/// Outgoing authentication message
#[derive(Debug, Serialize)]
struct AuthMessage {
    #[serde(rename = "type")]
    msg_type: &'static str,
    api_key: String,
    timestamp: u64,
    signature: String,
}

/// Outgoing subscribe message
#[derive(Debug, Serialize)]
struct SubscribeMessage {
    #[serde(rename = "type")]
    msg_type: &'static str,
    symbols: Vec<String>,
    channels: Vec<String>,
}

/// Incoming server message (generic)
#[derive(Debug, Deserialize)]
struct ServerMessage {
    #[serde(rename = "type")]
    msg_type: String,
    #[serde(default)]
    success: Option<bool>,
    #[serde(default)]
    error: Option<String>,
}

/// Incoming trade data
#[derive(Debug, Deserialize)]
struct Mt5Trade {
    time: u64,
    price: f64,
    volume: f64,
    side: String,
}

/// Incoming depth data
#[derive(Debug, Deserialize)]
struct Mt5Depth {
    time: u64,
    bids: Vec<[f64; 2]>,
    asks: Vec<[f64; 2]>,
}

/// Incoming kline data
#[derive(Debug, Deserialize)]
struct Mt5Kline {
    time: u64,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: f64,
}

/// Incoming symbol info
#[derive(Debug, Deserialize)]
struct Mt5SymbolInfo {
    symbol: String,
    tick_size: f64,
    min_lot: f64,
    contract_size: f64,
    #[allow(dead_code)]
    digits: i32,
}

/// Historical klines response
#[derive(Debug, Deserialize)]
struct KlinesResponse {
    data: Vec<Mt5Kline>,
}

/// Symbols list response
#[derive(Debug, Deserialize)]
struct SymbolsResponse {
    data: Vec<Mt5SymbolInfo>,
}

// ============================================================================
// Public API
// ============================================================================

/// Fetch available symbols from MT5 server via proxy
pub async fn fetch_ticksize(
    config: &Mt5Config,
) -> Result<HashMap<Ticker, Option<TickerInfo>>, AdapterError> {
    use futures_util::{SinkExt as _, StreamExt as _};
    use tokio_tungstenite::tungstenite::Message;

    log::info!("Fetching MT5 symbols from {}", config.server_addr);

    // Connect to proxy
    let url = config.ws_url();
    let (mut ws, _) = tokio_tungstenite::connect_async(&url)
        .await
        .map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

    // Authenticate
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    let signature = compute_hmac_signature(&config.api_key, timestamp, &config.api_secret);

    let auth_msg = serde_json::json!({
        "type": "auth",
        "api_key": config.api_key,
        "timestamp": timestamp,
        "signature": signature
    });

    ws.send(Message::Text(auth_msg.to_string()))
        .await
        .map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

    // Get auth response
    if let Some(Ok(Message::Text(text))) = ws.next().await {
        let resp: ServerMessage =
            serde_json::from_str(&text).map_err(|e| AdapterError::ParseError(e.to_string()))?;

        if resp.msg_type == "auth_response" && resp.success != Some(true) {
            return Err(AdapterError::WebsocketError(
                resp.error.unwrap_or_else(|| "Auth failed".to_string()),
            ));
        }
    }

    // Request symbols
    let symbols_req = serde_json::json!({ "type": "get_symbols" });
    ws.send(Message::Text(symbols_req.to_string()))
        .await
        .map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

    // Get symbols response
    let mut result = HashMap::new();

    if let Some(Ok(Message::Text(text))) = ws.next().await {
        if let Ok(resp) = serde_json::from_str::<SymbolsResponse>(&text) {
            for sym_info in resp.data {
                let ticker = Ticker::new(&sym_info.symbol, super::Exchange::MetaTrader5);
                let info = TickerInfo::new(
                    ticker,
                    sym_info.tick_size as f32,
                    sym_info.min_lot as f32,
                    Some(sym_info.contract_size as f32),
                );
                result.insert(ticker, Some(info));
            }
        }
    }

    ws.close(None).await.ok();

    Ok(result)
}

/// Fetch ticker prices/stats from MT5 server
pub async fn fetch_ticker_prices(
    _config: &Mt5Config,
) -> Result<HashMap<Ticker, TickerStats>, AdapterError> {
    // Prices come from the live stream, not a REST-like request
    Ok(HashMap::new())
}

/// Fetch historical klines from MT5 server
pub async fn fetch_klines(
    config: &Mt5Config,
    ticker_info: TickerInfo,
    timeframe: Timeframe,
    range: Option<(u64, u64)>,
) -> Result<Vec<Kline>, AdapterError> {
    use futures_util::{SinkExt as _, StreamExt as _};
    use tokio_tungstenite::tungstenite::Message;

    log::info!(
        "Fetching MT5 klines for {} {:?}",
        ticker_info.ticker,
        timeframe
    );

    // Connect to proxy
    let url = config.ws_url();
    let (mut ws, _) = tokio_tungstenite::connect_async(&url)
        .await
        .map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

    // Authenticate
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    let signature = compute_hmac_signature(&config.api_key, timestamp, &config.api_secret);

    let auth_msg = serde_json::json!({
        "type": "auth",
        "api_key": config.api_key,
        "timestamp": timestamp,
        "signature": signature
    });

    ws.send(Message::Text(auth_msg.to_string()))
        .await
        .map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

    // Wait for auth
    if let Some(Ok(Message::Text(text))) = ws.next().await {
        let resp: ServerMessage =
            serde_json::from_str(&text).map_err(|e| AdapterError::ParseError(e.to_string()))?;

        if resp.msg_type == "auth_response" && resp.success != Some(true) {
            return Err(AdapterError::WebsocketError(
                resp.error.unwrap_or_else(|| "Auth failed".to_string()),
            ));
        }
    }

    // Request klines
    let mut klines_req = serde_json::json!({
        "type": "get_klines",
        "symbol": ticker_info.ticker.to_string(),
        "timeframe": timeframe_to_mt5_string(timeframe),
        "limit": 500
    });

    if let Some((start, end)) = range {
        klines_req["start"] = serde_json::json!(start);
        klines_req["end"] = serde_json::json!(end);
    }

    ws.send(Message::Text(klines_req.to_string()))
        .await
        .map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

    // Get klines response
    let mut klines = Vec::new();

    if let Some(Ok(Message::Text(text))) = ws.next().await {
        if let Ok(resp) = serde_json::from_str::<KlinesResponse>(&text) {
            for k in resp.data {
                let buy_volume = (k.volume / 2.0) as f32;
                let sell_volume = (k.volume / 2.0) as f32;

                klines.push(Kline::new(
                    k.time,
                    k.open as f32,
                    k.high as f32,
                    k.low as f32,
                    k.close as f32,
                    (buy_volume, sell_volume),
                    ticker_info.min_ticksize,
                ));
            }
        }
    }

    ws.close(None).await.ok();

    Ok(klines)
}

/// Connect to MT5 market data stream
pub fn connect_market_stream(
    config: Mt5Config,
    ticker_info: TickerInfo,
    _push_freq: PushFrequency,
) -> impl Stream<Item = Event> {
    stream::channel(100, move |mut output| {
        let config = config.clone();

        async move {
            let exchange = super::Exchange::MetaTrader5;
            let mut orderbook = LocalDepthCache::default();
            let mut trades_buffer: Vec<Trade> = Vec::new();
            let mut reconnect_delay = Duration::from_secs(1);

            loop {
                log::info!("Connecting to MT5 proxy: {}", config.ws_url());

                match connect_and_stream(
                    &config,
                    ticker_info,
                    &mut orderbook,
                    &mut trades_buffer,
                    &mut output,
                )
                .await
                {
                    Ok(()) => {
                        let _ = output
                            .send(Event::Disconnected(
                                exchange,
                                "Connection closed".to_string(),
                            ))
                            .await;
                    }
                    Err(e) => {
                        log::error!("MT5 connection error: {}", e);
                        let _ = output
                            .send(Event::Disconnected(exchange, e.to_string()))
                            .await;
                    }
                }

                if !config.auto_reconnect {
                    break;
                }

                // Exponential backoff for reconnect
                tokio::time::sleep(reconnect_delay).await;
                reconnect_delay = std::cmp::min(reconnect_delay * 2, Duration::from_secs(60));
            }
        }
    })
}

/// Internal connection and streaming logic
async fn connect_and_stream(
    config: &Mt5Config,
    ticker_info: TickerInfo,
    orderbook: &mut LocalDepthCache,
    trades_buffer: &mut Vec<Trade>,
    output: &mut mpsc::Sender<Event>,
) -> Result<(), AdapterError> {
    use futures_util::{SinkExt as _, StreamExt as _};
    use tokio_tungstenite::tungstenite::Message;

    let exchange = super::Exchange::MetaTrader5;

    // Connect using tokio-tungstenite
    let url = config.ws_url();
    let (mut ws, _) = tokio_tungstenite::connect_async(&url)
        .await
        .map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

    // Send connected event
    let _ = output.send(Event::Connected(exchange)).await;

    // Authenticate
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    let signature = compute_hmac_signature(&config.api_key, timestamp, &config.api_secret);

    let auth_msg = AuthMessage {
        msg_type: "auth",
        api_key: config.api_key.clone(),
        timestamp,
        signature,
    };

    let auth_json =
        serde_json::to_string(&auth_msg).map_err(|e| AdapterError::ParseError(e.to_string()))?;

    ws.send(Message::Text(auth_json))
        .await
        .map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

    log::debug!("Sent auth message");

    // Wait for auth response
    let mut authenticated = false;
    while let Some(msg_result) = ws.next().await {
        let msg = msg_result.map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

        if let Message::Text(text) = msg {
            let server_msg: ServerMessage =
                serde_json::from_str(&text).map_err(|e| AdapterError::ParseError(e.to_string()))?;

            if server_msg.msg_type == "auth_response" {
                if server_msg.success == Some(true) {
                    authenticated = true;
                    log::info!("MT5 authenticated successfully");
                    break;
                } else {
                    return Err(AdapterError::WebsocketError(
                        server_msg
                            .error
                            .unwrap_or_else(|| "Auth failed".to_string()),
                    ));
                }
            }
        }
    }

    if !authenticated {
        return Err(AdapterError::WebsocketError(
            "No auth response received".to_string(),
        ));
    }

    // Subscribe to symbol
    let sub_msg = SubscribeMessage {
        msg_type: "subscribe",
        symbols: vec![ticker_info.ticker.to_string()],
        channels: vec!["trade".to_string(), "depth".to_string()],
    };

    let sub_json =
        serde_json::to_string(&sub_msg).map_err(|e| AdapterError::ParseError(e.to_string()))?;

    ws.send(Message::Text(sub_json))
        .await
        .map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

    log::debug!("Subscribed to {}", ticker_info.ticker);

    // Create StreamKind for events
    let stream_kind = StreamKind::DepthAndTrades {
        ticker_info,
        depth_aggr: StreamTicksize::Client,
        push_freq: PushFrequency::Realtime,
    };

    // Main message loop
    while let Some(msg_result) = ws.next().await {
        let msg = msg_result.map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

        match msg {
            Message::Text(text) => {
                // Parse message type
                if let Ok(server_msg) = serde_json::from_str::<ServerMessage>(&text) {
                    match server_msg.msg_type.as_str() {
                        "trade" => {
                            if let Ok(trade) = parse_trade(&text, ticker_info) {
                                trades_buffer.push(trade);
                            }
                        }
                        "depth" => {
                            if let Ok(depth_payload) = parse_depth(&text, ticker_info) {
                                // Update local depth cache
                                orderbook.update(
                                    DepthUpdate::Snapshot(depth_payload),
                                    ticker_info.min_ticksize,
                                );

                                // Emit depth received event
                                let trades: Box<[Trade]> =
                                    std::mem::take(trades_buffer).into_boxed_slice();

                                let _ = output
                                    .send(Event::DepthReceived(
                                        stream_kind,
                                        orderbook.time,
                                        Arc::clone(&orderbook.depth),
                                        trades,
                                    ))
                                    .await;
                            }
                        }
                        "heartbeat" => {
                            // Send pong response
                            let pong = serde_json::json!({
                                "type": "ping",
                                "time": std::time::SystemTime::now()
                                    .duration_since(std::time::UNIX_EPOCH)
                                    .unwrap()
                                    .as_millis() as u64
                            });
                            ws.send(Message::Text(pong.to_string())).await.ok();
                        }
                        "error" => {
                            log::error!(
                                "MT5 server error: {}",
                                server_msg.error.unwrap_or_default()
                            );
                        }
                        _ => {}
                    }
                }
            }
            Message::Ping(data) => {
                ws.send(Message::Pong(data)).await.ok();
            }
            Message::Close(_) => {
                log::info!("MT5 server sent close frame");
                break;
            }
            _ => {}
        }
    }

    Ok(())
}

/// Compute HMAC-SHA256 signature for authentication
fn compute_hmac_signature(api_key: &str, timestamp: u64, secret: &str) -> String {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;

    type HmacSha256 = Hmac<Sha256>;

    let message = format!("{}{}", api_key, timestamp);

    let mut mac =
        HmacSha256::new_from_slice(secret.as_bytes()).expect("HMAC can take key of any size");
    mac.update(message.as_bytes());

    let result = mac.finalize();
    hex::encode(result.into_bytes())
}

/// Parse incoming trade message
fn parse_trade(msg: &str, ticker_info: TickerInfo) -> Result<Trade, AdapterError> {
    let mt5_trade: Mt5Trade =
        serde_json::from_str(msg).map_err(|e| AdapterError::ParseError(e.to_string()))?;

    let is_sell = mt5_trade.side == "sell";
    let price =
        Price::from_f32(mt5_trade.price as f32).round_to_min_tick(ticker_info.min_ticksize);

    Ok(Trade {
        time: mt5_trade.time,
        is_sell,
        price,
        qty: mt5_trade.volume as f32,
    })
}

/// Parse incoming depth message
fn parse_depth(msg: &str, _ticker_info: TickerInfo) -> Result<DepthPayload, AdapterError> {
    let mt5_depth: Mt5Depth =
        serde_json::from_str(msg).map_err(|e| AdapterError::ParseError(e.to_string()))?;

    let bids = mt5_depth
        .bids
        .iter()
        .map(|[price, qty]| crate::depth::DeOrder {
            price: *price as f32,
            qty: *qty as f32,
        })
        .collect();

    let asks = mt5_depth
        .asks
        .iter()
        .map(|[price, qty]| crate::depth::DeOrder {
            price: *price as f32,
            qty: *qty as f32,
        })
        .collect();

    Ok(DepthPayload {
        last_update_id: mt5_depth.time,
        time: mt5_depth.time,
        bids,
        asks,
    })
}

/// Convert timeframe to MT5 string format
fn timeframe_to_mt5_string(tf: Timeframe) -> &'static str {
    match tf {
        Timeframe::M1 => "M1",
        Timeframe::M3 => "M3",
        Timeframe::M5 => "M5",
        Timeframe::M15 => "M15",
        Timeframe::M30 => "M30",
        Timeframe::H1 => "H1",
        Timeframe::H2 => "H2",
        Timeframe::H4 => "H4",
        Timeframe::H12 => "H12",
        Timeframe::D1 => "D1",
        _ => "M1",
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_config_validation() {
        let mut config = Mt5Config::default();
        assert!(config.validate().is_err());

        config.api_key = "test_key".to_string();
        assert!(config.validate().is_err());

        config.api_secret = "test_secret".to_string();
        assert!(config.validate().is_ok());
    }

    #[test]
    fn test_ws_url() {
        let config = Mt5Config {
            server_addr: "192.168.1.100:9876".to_string(),
            use_tls: false,
            ..Default::default()
        };
        assert_eq!(config.ws_url(), "ws://192.168.1.100:9876/client");

        let config_tls = Mt5Config {
            server_addr: "example.com:9876".to_string(),
            use_tls: true,
            ..Default::default()
        };
        assert_eq!(config_tls.ws_url(), "wss://example.com:9876/client");
    }

    #[test]
    fn test_hmac_signature() {
        let signature = compute_hmac_signature("test_key", 1704355200000, "secret");
        assert!(!signature.is_empty());
        assert_eq!(signature.len(), 64); // SHA-256 produces 32 bytes = 64 hex chars
    }
}
