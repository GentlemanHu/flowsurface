# Flowsurface Architecture

## Overview

Flowsurface is a native desktop charting application built with Rust and the [iced](https://github.com/iced-rs/iced) GUI framework. It provides real-time market data visualization for crypto exchanges and MetaTrader 5.

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Flowsurface UI                           │
│                     (iced GUI Framework)                        │
├─────────────────────────────────────────────────────────────────┤
│                       Chart Components                          │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ Heatmap  │  │Footprint │  │ Candles  │  │   DOM    │      │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘      │
├─────────────────────────────────────────────────────────────────┤
│                     Exchange Adapters                           │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐      │
│  │ Binance  │  │  Bybit   │  │Hyperliquid│  │   MT5    │      │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘      │
│       │             │              │              │             │
│       ▼             ▼              ▼              ▼             │
│  WebSocket     WebSocket      WebSocket       TCP Client       │
└───────┼─────────────┼──────────────┼──────────────┼────────────┘
        │             │              │              │
        ▼             ▼              ▼              ▼
┌─────────────┐ ┌──────────┐ ┌─────────────┐ ┌──────────────┐
│   Binance   │ │  Bybit   │ │ Hyperliquid │ │ MetaTrader 5 │
│   Servers   │ │  Servers │ │   Servers   │ │  (TCP Server)│
└─────────────┘ └──────────┘ └─────────────┘ └──────────────┘
```

## MetaTrader 5 Integration Architecture

### Overview

The MT5 integration uses a **reversed client-server model** where MT5 acts as the **server** and Flowsurface acts as the **client**.

### Architecture Diagram

```
┌─────────────────────────────────┐         ┌─────────────────────────────────┐
│      MetaTrader 5 Terminal      │         │       Flowsurface Client        │
│                                 │         │                                 │
│  ┌───────────────────────────┐ │         │  ┌───────────────────────────┐ │
│  │  FlowsurfaceConnector.mq5 │ │         │  │   MT5 Adapter (Rust)      │ │
│  │  (Expert Advisor)         │ │         │  │   - TCP Client            │ │
│  │  - TCP Server             │ │         │  │   - Data Parser           │ │
│  │  - Market Data Provider   │ │         │  │   - Event Handler         │ │
│  │  - Listen on Port 7878    │◄├─────────┤─►│   - Connects to MT5       │ │
│  │  - Accept Connections     │ │  TCP    │  │   - Reconnection Logic    │ │
│  │  - Stream Data            │ │         │  │                           │ │
│  └───────────────────────────┘ │         │  └───────────────────────────┘ │
│                                 │         │                                 │
│  ┌───────────────────────────┐ │         │  ┌───────────────────────────┐ │
│  │    Market Data Sources    │ │         │  │    Chart Components       │ │
│  │  - Orderbook (DOM)        │ │         │  │  - Heatmap                │ │
│  │  - Trades                 │ │         │  │  - Footprint              │ │
│  │  - Candlesticks           │ │         │  │  - DOM Ladder             │ │
│  │  - Symbol Info            │ │         │  │                           │ │
│  └───────────────────────────┘ │         │  └───────────────────────────┘ │
└─────────────────────────────────┘         └─────────────────────────────────┘
         SERVER                                        CLIENT
    (Data Provider)                              (Data Consumer)
```

### Why This Architecture?

**Original Design**: Flowsurface was initially designed with MT5 as a client connecting to Flowsurface's server.

**Current Design (Reversed)**: MT5 now acts as the server, Flowsurface as the client.

**Benefits of the Reversed Architecture**:

1. **Remote Connections**: Connect to MT5 running on a different machine or VPS
2. **Flexibility**: Run MT5 on a powerful server and connect from any client
3. **Multiple Clients**: Potentially support multiple Flowsurface instances connecting to one MT5 (future)
4. **Reliability**: MT5 remains stable as the data source; clients can reconnect
5. **Cross-Platform**: Run MT5 on Windows/VPS, connect from any OS running Flowsurface

### Data Flow

1. **Initialization**:
   - MT5 EA starts TCP server on port 7878
   - Flowsurface connects as TCP client
   - EA sends ticker info (symbol specs, tick size, etc.)

2. **Real-Time Updates**:
   - MT5 captures market events (trades, orderbook updates, new candles)
   - EA formats data as JSON messages
   - Messages sent to Flowsurface via TCP connection
   - Flowsurface parses and renders data

3. **Reconnection**:
   - If connection drops, Flowsurface retries every 5 seconds
   - MT5 EA accepts new connection automatically
   - Data streaming resumes

### Connection Formats

**Local Connection**:
```
Symbol: XAUUSD
Connects to: 127.0.0.1:7878
```

**Remote Connection**:
```
Symbol: XAUUSD@192.168.1.100:7878
Connects to: 192.168.1.100:7878
```

**VPS Connection**:
```
Symbol: XAUUSD@mt5.example.com:7878
Connects to: mt5.example.com:7878
```

### Message Protocol

All messages are JSON-formatted, newline-delimited text over TCP.

**Ticker Info** (sent on connection):
```json
{
  "type": "ticker_info",
  "symbol": "XAUUSD",
  "tick_size": 0.01,
  "min_qty": 0.01,
  "digits": 2
}
```

**Trade Data**:
```json
{
  "type": "trade",
  "symbol": "XAUUSD",
  "time": 1703686800000,
  "price": 2045.50,
  "volume": 0.10,
  "is_sell": false
}
```

**Market Depth**:
```json
{
  "type": "depth",
  "symbol": "XAUUSD",
  "time": 1703686800000,
  "bids": [[2045.50, 10.5], [2045.40, 8.2]],
  "asks": [[2045.60, 12.3], [2045.70, 9.1]]
}
```

**Kline/Candlestick**:
```json
{
  "type": "kline",
  "symbol": "XAUUSD",
  "time": 1703686800000,
  "open": 2044.00,
  "high": 2046.50,
  "low": 2043.20,
  "close": 2045.50,
  "volume": 1250.5,
  "timeframe": "M1"
}
```

## Exchange Adapters

Each exchange has its own adapter implementing:
- REST API client for historical data
- WebSocket client for real-time data
- Data normalization to common formats
- Rate limiting and error handling

### Common Adapter Interface

```rust
pub trait ExchangeAdapter {
    async fn fetch_ticksize() -> Result<HashMap<Ticker, TickerInfo>>;
    async fn fetch_ticker_prices() -> Result<HashMap<Ticker, TickerStats>>;
    async fn fetch_klines(ticker_info, timeframe, range) -> Result<Vec<Kline>>;
    fn connect_market_stream(ticker_info, push_freq) -> Stream<Event>;
    fn connect_kline_stream(ticker_info, timeframe) -> Stream<Event>;
}
```

## Data Types

### Core Market Data Types

- **Trade**: Single trade execution with price, quantity, timestamp, side
- **Kline**: OHLCV candlestick data for a time period
- **Depth**: Order book snapshot with bids and asks
- **TickerInfo**: Symbol specifications (tick size, min quantity, etc.)

### Chart Components

- **Heatmap**: Time-series visualization of volume at price levels
- **Footprint**: Trade analysis showing buy/sell volume per price level
- **Candlestick**: Traditional OHLC chart
- **DOM**: Real-time order book display
- **Time & Sales**: Scrollable trade history

## Threading and Concurrency

- **Main Thread**: UI rendering and event handling (iced event loop)
- **Background Tasks**: Async tasks for network I/O (tokio runtime)
- **Data Streams**: Each exchange connection runs in its own async task
- **Message Passing**: Channels for communication between tasks and UI

## State Management

- **Application State**: Centralized state tree managed by iced
- **Local State**: Each component maintains its own state
- **Persistent State**: Saved to disk (layouts, themes, preferences)

## File Structure

```
flowsurface/
├── src/
│   ├── main.rs              # Application entry point
│   ├── screen/              # UI screens
│   │   └── dashboard.rs     # Main dashboard
│   ├── chart/               # Chart components
│   │   ├── heatmap.rs
│   │   ├── footprint.rs
│   │   └── candlestick.rs
│   └── style.rs             # Theming and styling
├── exchange/
│   └── src/
│       ├── lib.rs           # Exchange module root
│       └── adapter/         # Exchange adapters
│           ├── binance.rs
│           ├── bybit.rs
│           ├── hyperliquid.rs
│           ├── okex.rs
│           └── metatrader5.rs
├── data/                    # Data storage module
├── mql5/                    # MetaTrader 5 integration
│   ├── FlowsurfaceConnector.mq5
│   └── README.md
└── docs/                    # Documentation
    └── ARCHITECTURE.md
```

## Security Considerations

### General
- No API keys stored (uses public market data endpoints)
- All connections use secure WebSocket (wss://) where available
- Local data storage uses OS-appropriate directories

### MT5 Integration
- TCP connections are unencrypted by default
- For local use: Safe (localhost only)
- For remote use: 
  - Use VPN or SSH tunnel for encryption
  - Firewall rules to restrict access
  - Non-standard ports to reduce exposure
  - Monitor connection logs

## Performance Optimization

- **Efficient Rendering**: Only redraw when data changes
- **Data Buffering**: Batch updates to reduce overhead
- **Memory Management**: Circular buffers for historical data
- **CPU Usage**: Configurable update intervals
- **GPU Rendering**: Hardware-accelerated canvas via wgpu

## Future Improvements

- [ ] Multiple MT5 instances support
- [ ] Authentication for MT5 connections
- [ ] Encrypted MT5 connections (TLS/SSL)
- [ ] Bidirectional communication (send orders to MT5)
- [ ] WebSocket support for MT5 (instead of raw TCP)
- [ ] Compression for high-frequency data
