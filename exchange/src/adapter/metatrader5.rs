use super::{
    super::{
        Exchange, Kline, MarketKind, Price, PushFrequency, SizeUnit, StreamKind, Ticker,
        TickerInfo, TickerStats, Timeframe, Trade,
        adapter::StreamTicksize,
        depth::{DeOrder, DepthPayload, DepthUpdate, LocalDepthCache},
        volume_size_unit,
    },
    AdapterError, Event,
};

use iced_futures::{
    futures::{SinkExt, Stream, channel::mpsc},
    stream,
};
use serde::Deserialize;
use std::collections::HashMap;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::TcpStream;

const DEFAULT_PORT: u16 = 7878;
const DEFAULT_HOST: &str = "127.0.0.1";

/// Parse MT5 connection string from ticker metadata
/// Format: "SYMBOL@HOST:PORT" or "SYMBOL" (uses defaults)
fn parse_mt5_connection(ticker: &Ticker) -> (String, String, u16) {
    let (symbol_str, _) = ticker.to_full_symbol_and_type();
    
    // Check if symbol contains connection info
    if let Some(at_pos) = symbol_str.find('@') {
        let symbol = symbol_str[..at_pos].to_string();
        let connection = &symbol_str[at_pos + 1..];
        
        if let Some(colon_pos) = connection.find(':') {
            let host = connection[..colon_pos].to_string();
            let port_str = &connection[colon_pos + 1..];
            let port = match port_str.parse::<u16>() {
                Ok(p) => p,
                Err(e) => {
                    log::warn!(
                        "Failed to parse port '{}' in connection string '{}': {}. Using default port {}",
                        port_str, symbol_str, e, DEFAULT_PORT
                    );
                    DEFAULT_PORT
                }
            };
            (symbol, host, port)
        } else {
            (symbol, connection.to_string(), DEFAULT_PORT)
        }
    } else {
        (symbol_str, DEFAULT_HOST.to_string(), DEFAULT_PORT)
    }
}

fn exchange_from_market_type(market: MarketKind) -> Exchange {
    match market {
        MarketKind::Spot => Exchange::MetaTrader5Spot,
        _ => Exchange::MetaTrader5Spot, // MT5 adapter only supports Spot for now
    }
}

/// MT5 data message types sent from the EA
#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Mt5Message {
    #[serde(rename = "ticker_info")]
    #[allow(dead_code)]
    TickerInfo(Mt5TickerInfo),
    #[serde(rename = "trade")]
    Trade(Mt5Trade),
    #[serde(rename = "depth")]
    Depth(Mt5Depth),
    #[serde(rename = "kline")]
    Kline(Mt5Kline),
    #[serde(rename = "ticker_price")]
    #[allow(dead_code)]
    TickerPrice(Mt5TickerPrice),
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct Mt5TickerInfo {
    symbol: String,
    tick_size: f32,
    min_qty: f32,
    digits: i32,
}

#[derive(Debug, Deserialize)]
struct Mt5Trade {
    #[allow(dead_code)]
    symbol: String,
    time: u64,
    price: f32,
    volume: f32,
    is_sell: bool,
}

#[derive(Debug, Deserialize)]
struct Mt5Depth {
    #[allow(dead_code)]
    symbol: String,
    time: u64,
    bids: Vec<[f32; 2]>, // [price, volume]
    asks: Vec<[f32; 2]>, // [price, volume]
}

#[derive(Debug, Deserialize)]
struct Mt5Kline {
    #[allow(dead_code)]
    symbol: String,
    time: u64,
    open: f32,
    high: f32,
    low: f32,
    close: f32,
    volume: f32,
    timeframe: String,
}

#[derive(Debug, Deserialize)]
#[allow(dead_code)]
struct Mt5TickerPrice {
    symbol: String,
    bid: f32,
    ask: f32,
    last: f32,
    volume: f32,
}

/// Fetch ticker information from MT5
/// Since MT5 is a local connection, we return a simple placeholder or error
/// The actual ticker info will come through the websocket connection
pub async fn fetch_ticksize(
    market: MarketKind,
) -> Result<HashMap<Ticker, Option<TickerInfo>>, AdapterError> {
    if market != MarketKind::Spot {
        return Err(AdapterError::InvalidRequest(
            "MetaTrader5 only supports Spot market".to_string(),
        ));
    }

    // Return empty map - ticker info will be received via MT5 EA connection
    Ok(HashMap::new())
}

pub async fn fetch_ticker_prices(
    market: MarketKind,
) -> Result<HashMap<Ticker, TickerStats>, AdapterError> {
    if market != MarketKind::Spot {
        return Err(AdapterError::InvalidRequest(
            "MetaTrader5 only supports Spot market".to_string(),
        ));
    }

    // Return empty map - ticker prices will be received via MT5 EA connection
    Ok(HashMap::new())
}

pub async fn fetch_klines(
    _ticker_info: TickerInfo,
    _timeframe: Timeframe,
    _range: Option<(u64, u64)>,
) -> Result<Vec<Kline>, AdapterError> {
    // MT5 klines are received via the EA connection, not via REST API
    Ok(Vec::new())
}

/// Connect to MT5 market data stream
/// This creates a TCP client that connects to the MT5 EA server
pub fn connect_market_stream(
    ticker_info: TickerInfo,
    _push_freq: PushFrequency,
) -> impl Stream<Item = Event> {
    stream::channel(100, move |mut output: mpsc::Sender<Event>| async move {
        let ticker = ticker_info.ticker;
        let (symbol_str, host, port) = parse_mt5_connection(&ticker);
        let (_original_symbol, market) = ticker.to_full_symbol_and_type();
        let exchange = exchange_from_market_type(market);

        let mut orderbook: LocalDepthCache = LocalDepthCache::default();
        let mut trades_buffer: Vec<Trade> = Vec::new();

        log::info!("Starting MT5 market stream for {} (connecting to {}:{})", symbol_str, host, port);

        // Connect to MT5 EA server with retry logic
        loop {
            match TcpStream::connect(format!("{}:{}", host, port)).await {
                Ok(stream) => {
                    log::info!("Connected to MT5 EA at {}:{}", host, port);
                    let _ = output.send(Event::Connected(exchange)).await;

                    // Handle the connection
                    if let Err(e) = handle_mt5_connection(
                        stream,
                        ticker_info,
                        &mut orderbook,
                        &mut trades_buffer,
                        &mut output,
                    )
                    .await
                    {
                        log::error!("MT5 connection error: {}", e);
                        let _ = output
                            .send(Event::Disconnected(
                                exchange,
                                format!("Connection error: {}", e),
                            ))
                            .await;
                    }

                    // Connection lost, wait before reconnecting
                    log::info!("Attempting to reconnect to MT5 EA in 5 seconds...");
                    tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
                }
                Err(e) => {
                    log::error!("Failed to connect to MT5 EA at {}:{} - {}", host, port, e);
                    let _ = output
                        .send(Event::Disconnected(
                            exchange,
                            format!("Failed to connect: {}", e),
                        ))
                        .await;

                    // Wait before retrying
                    tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
                }
            }
        }
    })
}

async fn handle_mt5_connection(
    stream: TcpStream,
    ticker_info: TickerInfo,
    orderbook: &mut LocalDepthCache,
    trades_buffer: &mut Vec<Trade>,
    output: &mut mpsc::Sender<Event>,
) -> Result<(), String> {
    let mut reader = BufReader::new(stream);
    let mut line = String::new();

    let size_in_quote_ccy = volume_size_unit() == SizeUnit::Quote;

    loop {
        line.clear();
        match reader.read_line(&mut line).await {
            Ok(0) => {
                // Connection closed
                log::info!("MT5 EA disconnected");
                return Err("Connection closed".to_string());
            }
            Ok(_) => {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }

                // Parse the JSON message
                match serde_json::from_str::<Mt5Message>(trimmed) {
                    Ok(msg) => {
                        if let Err(e) = process_mt5_message(
                            msg,
                            ticker_info,
                            orderbook,
                            trades_buffer,
                            output,
                            size_in_quote_ccy,
                        )
                        .await
                        {
                            log::error!("Error processing MT5 message: {}", e);
                        }
                    }
                    Err(e) => {
                        log::error!("Failed to parse MT5 message: {} - Data: {}", e, trimmed);
                    }
                }
            }
            Err(e) => {
                log::error!("Failed to read from MT5 EA: {}", e);
                return Err(format!("Read error: {}", e));
            }
        }
    }
}

async fn process_mt5_message(
    msg: Mt5Message,
    ticker_info: TickerInfo,
    orderbook: &mut LocalDepthCache,
    trades_buffer: &mut Vec<Trade>,
    output: &mut mpsc::Sender<Event>,
    size_in_quote_ccy: bool,
) -> Result<(), String> {
    match msg {
        Mt5Message::Trade(mt5_trade) => {
            // Calculate quantity with overflow protection
            let qty = if size_in_quote_ccy {
                (mt5_trade.volume as f64 * mt5_trade.price as f64) as f32
            } else {
                mt5_trade.volume
            };

            let trade = Trade {
                time: mt5_trade.time,
                is_sell: mt5_trade.is_sell,
                price: Price::from_f32(mt5_trade.price).round_to_min_tick(ticker_info.min_ticksize),
                qty,
            };

            trades_buffer.push(trade);
        }
        Mt5Message::Depth(mt5_depth) => {
            // Convert MT5 depth to our depth format
            let bids: Vec<DeOrder> = mt5_depth
                .bids
                .iter()
                .map(|[price, volume]| DeOrder {
                    price: *price,
                    qty: *volume,
                })
                .collect();

            let asks: Vec<DeOrder> = mt5_depth
                .asks
                .iter()
                .map(|[price, volume]| DeOrder {
                    price: *price,
                    qty: *volume,
                })
                .collect();

            let payload = DepthPayload {
                last_update_id: 0,
                time: mt5_depth.time,
                bids,
                asks,
            };

            // Update the orderbook with the snapshot
            orderbook.update(DepthUpdate::Snapshot(payload), ticker_info.min_ticksize);

            // Send depth and trades
            let stream_kind = StreamKind::DepthAndTrades {
                ticker_info,
                depth_aggr: StreamTicksize::Client,
                push_freq: PushFrequency::ServerDefault,
            };

            let depth_arc = orderbook.depth.clone();
            let trades_box: Box<[Trade]> = trades_buffer.drain(..).collect();

            let _ = output
                .send(Event::DepthReceived(
                    stream_kind,
                    mt5_depth.time,
                    depth_arc,
                    trades_box,
                ))
                .await;
        }
        Mt5Message::Kline(mt5_kline) => {
            let kline = Kline {
                time: mt5_kline.time,
                open: Price::from_f32(mt5_kline.open).round_to_min_tick(ticker_info.min_ticksize),
                high: Price::from_f32(mt5_kline.high).round_to_min_tick(ticker_info.min_ticksize),
                low: Price::from_f32(mt5_kline.low).round_to_min_tick(ticker_info.min_ticksize),
                close: Price::from_f32(mt5_kline.close).round_to_min_tick(ticker_info.min_ticksize),
                volume: (mt5_kline.volume, 0.0), // MT5 doesn't separate buy/sell volume
            };

            let timeframe = parse_mt5_timeframe(&mt5_kline.timeframe)?;

            let stream_kind = StreamKind::Kline {
                ticker_info,
                timeframe,
            };

            let _ = output.send(Event::KlineReceived(stream_kind, kline)).await;
        }
        Mt5Message::TickerInfo(_) => {
            // Ticker info messages could be used to update symbol specifications
            log::debug!("Received ticker info from MT5");
        }
        Mt5Message::TickerPrice(_) => {
            // Ticker price messages for statistics
            log::debug!("Received ticker price from MT5");
        }
    }

    Ok(())
}

fn parse_mt5_timeframe(tf_str: &str) -> Result<Timeframe, String> {
    match tf_str {
        "M1" => Ok(Timeframe::M1),
        "M3" => Ok(Timeframe::M3),
        "M5" => Ok(Timeframe::M5),
        "M15" => Ok(Timeframe::M15),
        "M30" => Ok(Timeframe::M30),
        "H1" => Ok(Timeframe::H1),
        "H2" => Ok(Timeframe::H2),
        "H4" => Ok(Timeframe::H4),
        "H12" => Ok(Timeframe::H12),
        "D1" => Ok(Timeframe::D1),
        _ => Err(format!("Unsupported MT5 timeframe: {}", tf_str)),
    }
}

/// Connect to MT5 kline stream
pub fn connect_kline_stream(
    ticker_info: TickerInfo,
    timeframe: Timeframe,
) -> impl Stream<Item = Event> {
    stream::channel(100, move |mut output: mpsc::Sender<Event>| async move {
        let ticker = ticker_info.ticker;
        let (symbol_str, market) = ticker.to_full_symbol_and_type();
        let exchange = exchange_from_market_type(market);

        log::info!(
            "Starting MT5 kline stream for {} - {}",
            symbol_str,
            timeframe
        );

        // Klines are received through the market stream connection
        // This is a placeholder that could be expanded for dedicated kline streams
        let _ = output.send(Event::Connected(exchange)).await;

        // Keep the stream alive
        loop {
            tokio::time::sleep(tokio::time::Duration::from_secs(60)).await;
        }
    })
}
