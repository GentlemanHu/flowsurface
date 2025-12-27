# MetaTrader 5 Integration

This document describes how the MetaTrader 5 integration works with Flowsurface.

## Architecture

The MetaTrader 5 integration uses a client-server architecture where:

1. **Flowsurface (Server)**: The Rust application acts as a TCP server listening on port 7878
2. **MT5 Expert Advisor (Client)**: An MQL5 Expert Advisor running in MetaTrader 5 connects to Flowsurface and streams market data

### Data Flow

```
MetaTrader 5 Terminal
    └── FlowsurfaceConnector EA (MQL5)
            ↓ TCP Socket (JSON)
            ↓ Port 7878
        Flowsurface Application (Rust)
            └── MT5 Adapter
                ├── Parse market data
                ├── Update orderbook
                └── Generate events for UI
```

## Quick Start

See `mql5/README.md` for installation and setup instructions.

## Message Protocol

All messages are JSON objects sent as single lines (newline-delimited JSON).

### Message Types

#### 1. Ticker Info
```json
{
  "type": "ticker_info",
  "symbol": "XAUUSD",
  "tick_size": 0.01,
  "min_qty": 0.01,
  "digits": 2
}
```

#### 2. Trade
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

#### 3. Depth (Orderbook)
```json
{
  "type": "depth",
  "symbol": "XAUUSD",
  "time": 1703686800000,
  "bids": [[2045.50, 10.5], [2045.40, 8.2]],
  "asks": [[2045.60, 12.3], [2045.70, 9.1]]
}
```

#### 4. Kline
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

## Configuration

### Flowsurface
- Default port: 7878 (defined in `exchange/src/adapter/metatrader5.rs`)

### MT5 EA Parameters
- `FlowsurfaceHost`: "127.0.0.1"
- `FlowsurfacePort`: 7878
- `DepthLevels`: 10
- `UpdateIntervalMs`: 100
- `SendTrades`, `SendDepth`, `SendKlines`: true/false

## Supported Symbols

Works with any MT5 symbol: Forex, Metals (XAUUSD, XAGUSD), Indices, Crypto

## Features & Limitations

### Features
- Real-time tick data (< 100ms latency)
- Full orderbook depth (DOM)
- Candlestick data for all timeframes
- Footprint chart support

### Limitations
- Market depth requires broker support
- Single symbol per EA instance
- No historical data replay
- Tick volume (not actual volume)

## Troubleshooting

See `mql5/README.md` for detailed troubleshooting steps.
