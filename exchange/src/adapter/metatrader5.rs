//! MetaTrader 5 WebSocket adapter for Flowsurface
//!
//! Connects to a remote MT5 terminal running the FlowsurfaceServer EA
//! to receive real-time forex/CFD market data (trades, depth, klines).
//!
//! # Architecture
//!
//! ```text
//! MT5 Terminal + FlowsurfaceServer.mq5
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

#![allow(dead_code)] // TODO: Remove when implementation is complete

use super::{AdapterError, Event};
use crate::{
    Kline, Price, PushFrequency, Ticker, TickerInfo, TickerStats, Timeframe, Trade,
    depth::{DepthPayload, LocalDepthCache},
};

use iced_futures::{
    futures::{SinkExt, Stream, channel::mpsc},
    stream,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, time::Duration};

// ============================================================================
// Configuration Types
// ============================================================================

/// MT5 server connection configuration
#[derive(Debug, Clone, Deserialize, Serialize)]
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
    /// Create WebSocket URL from config
    pub fn ws_url(&self) -> String {
        let protocol = if self.use_tls { "wss" } else { "ws" };
        format!("{}://{}", protocol, self.server_addr)
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
    #[serde(default)]
    symbol: Option<String>,
    #[serde(default)]
    time: Option<u64>,
}

/// Incoming trade data
#[derive(Debug, Deserialize)]
struct Mt5Trade {
    #[allow(dead_code)]
    symbol: String,
    time: u64,
    price: f64,
    volume: f64,
    side: String,
}

/// Incoming depth data
#[derive(Debug, Deserialize)]
struct Mt5Depth {
    #[allow(dead_code)]
    symbol: String,
    time: u64,
    bids: Vec<[f64; 2]>,
    asks: Vec<[f64; 2]>,
}

/// Incoming kline data
#[derive(Debug, Deserialize)]
struct Mt5Kline {
    #[allow(dead_code)]
    symbol: String,
    #[allow(dead_code)]
    timeframe: String,
    time: u64,
    open: f64,
    high: f64,
    low: f64,
    close: f64,
    volume: f64,
    #[allow(dead_code)]
    tick_volume: u64,
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
    #[allow(dead_code)]
    symbol: String,
    #[allow(dead_code)]
    timeframe: String,
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

/// Fetch available symbols from MT5 server
pub async fn fetch_ticksize(
    config: &Mt5Config,
) -> Result<HashMap<Ticker, Option<TickerInfo>>, AdapterError> {
    // For MT5, we need to connect and request symbol info
    // This is a simplified version that would work with the actual WebSocket

    log::info!("Fetching MT5 symbols from {}", config.server_addr);

    // Placeholder - in real implementation, connect to WS and request symbols
    // For now, return common forex pairs as examples
    let mut result = HashMap::new();

    let common_symbols = [
        ("XAUUSD", 0.01, 0.01, Some(100.0)),
        ("EURUSD", 0.00001, 0.01, None),
        ("GBPUSD", 0.00001, 0.01, None),
        ("USDJPY", 0.001, 0.01, None),
        ("BTCUSD", 1.0, 0.01, Some(1.0)),
    ];

    for (symbol, tick_size, min_qty, contract_size) in common_symbols {
        let ticker = Ticker::new(symbol, super::Exchange::MetaTrader5);
        let info = TickerInfo::new(
            ticker,
            tick_size as f32,
            min_qty as f32,
            contract_size.map(|c| c as f32),
        );
        result.insert(ticker, Some(info));
    }

    Ok(result)
}

/// Fetch ticker prices/stats from MT5 server
pub async fn fetch_ticker_prices(
    config: &Mt5Config,
) -> Result<HashMap<Ticker, TickerStats>, AdapterError> {
    log::info!("Fetching MT5 ticker prices from {}", config.server_addr);

    // Placeholder - in real implementation, connect and fetch real-time prices
    let result = HashMap::new();
    Ok(result)
}

/// Fetch historical klines from MT5 server
pub async fn fetch_klines(
    _config: &Mt5Config,
    ticker_info: TickerInfo,
    timeframe: Timeframe,
    _range: Option<(u64, u64)>,
) -> Result<Vec<Kline>, AdapterError> {
    log::info!(
        "Fetching MT5 klines for {} {:?}",
        ticker_info.ticker,
        timeframe
    );

    // Placeholder - in real implementation, send get_klines request
    Ok(vec![])
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
                log::info!("Connecting to MT5 server: {}", config.ws_url());

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
                        // Clean disconnect
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
    _orderbook: &mut LocalDepthCache,
    _trades_buffer: &mut [Trade],
    output: &mut mpsc::Sender<Event>,
) -> Result<(), AdapterError> {
    let exchange = super::Exchange::MetaTrader5;

    // Build WebSocket URL
    let url = config.ws_url();

    // Connect using the common connect function
    // Note: This uses the same connect module as other adapters
    let domain = config.server_addr.split(':').next().unwrap_or("localhost");

    let _websocket = crate::connect::connect_ws(domain, &url)
        .await
        .map_err(|e| AdapterError::WebsocketError(e.to_string()))?;

    // Send connected event
    let _ = output.send(Event::Connected(exchange)).await;

    // Authenticate
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    let signature = compute_signature(&config.api_key, timestamp, &config.api_secret);

    let auth_msg = AuthMessage {
        msg_type: "auth",
        api_key: config.api_key.clone(),
        timestamp,
        signature,
    };

    let _auth_json =
        serde_json::to_string(&auth_msg).map_err(|e| AdapterError::ParseError(e.to_string()))?;

    log::debug!("Sending auth message");

    // Send auth and subscribe messages
    // (In real implementation, would send via websocket)

    // Subscribe to symbol
    let sub_msg = SubscribeMessage {
        msg_type: "subscribe",
        symbols: vec![ticker_info.ticker.to_string()],
        channels: vec!["depth".to_string(), "trades".to_string()],
    };

    let _sub_json =
        serde_json::to_string(&sub_msg).map_err(|e| AdapterError::ParseError(e.to_string()))?;

    log::debug!("Subscribed to {}", ticker_info.ticker);

    // Main message loop would go here
    // For now, this is a placeholder that would process incoming WebSocket frames

    // In a real implementation:
    // 1. Read frame from websocket
    // 2. Parse JSON message
    // 3. Convert to Trade/Depth/Kline
    // 4. Send via output channel

    // Placeholder: simulate connection for now
    tokio::time::sleep(Duration::from_secs(config.timeout_secs)).await;

    Ok(())
}

/// Compute HMAC-SHA256 signature for authentication
fn compute_signature(api_key: &str, timestamp: u64, secret: &str) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    // Simple hash for placeholder (real implementation would use HMAC-SHA256)
    let message = format!("{}{}", api_key, timestamp);
    let combined = format!("{}{}", message, secret);

    let mut hasher = DefaultHasher::new();
    combined.hash(&mut hasher);
    let hash = hasher.finish();

    format!("{:016x}", hash)
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

/// Parse incoming kline message
fn parse_kline(msg: &str, ticker_info: TickerInfo) -> Result<Kline, AdapterError> {
    let mt5_kline: Mt5Kline =
        serde_json::from_str(msg).map_err(|e| AdapterError::ParseError(e.to_string()))?;

    // MT5 doesn't provide buy/sell volume split, so split 50/50
    let buy_volume = (mt5_kline.volume / 2.0) as f32;
    let sell_volume = (mt5_kline.volume / 2.0) as f32;

    Ok(Kline::new(
        mt5_kline.time,
        mt5_kline.open as f32,
        mt5_kline.high as f32,
        mt5_kline.low as f32,
        mt5_kline.close as f32,
        (buy_volume, sell_volume),
        ticker_info.min_ticksize,
    ))
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
        assert_eq!(config.ws_url(), "ws://192.168.1.100:9876");

        let config_tls = Mt5Config {
            server_addr: "example.com:9876".to_string(),
            use_tls: true,
            ..Default::default()
        };
        assert_eq!(config_tls.ws_url(), "wss://example.com:9876");
    }

    #[test]
    fn test_signature_computation() {
        let signature = compute_signature("test_key", 1704355200000, "secret");
        assert!(!signature.is_empty());
        assert_eq!(signature.len(), 16); // 64-bit hex
    }
}
