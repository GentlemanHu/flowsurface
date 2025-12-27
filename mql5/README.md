# MetaTrader 5 Integration for Flowsurface

This directory contains the MQL5 Expert Advisor (EA) that enables MetaTrader 5 to send market data to Flowsurface.

## Architecture

The MT5 integration uses a **client-server architecture**:

- **Flowsurface** = TCP Server (listens on port 7878)
- **MT5 Expert Advisor** = TCP Client (connects to Flowsurface)

This design allows:
- **Multiple symbols**: Run the EA on multiple MT5 charts simultaneously, each sending data for different symbols
- **Cross-platform support**: MT5 (typically Windows) can connect to Flowsurface running on Windows, Mac, or Linux
- **Network flexibility**: Connect locally (127.0.0.1) or over a network (configure IP address in EA settings)

## Overview

The Flowsurface Connector EA establishes a TCP connection to the Flowsurface application and streams real-time market data including:
- **Trade Data**: Individual trades with price, volume, and direction
- **Market Depth**: Order book data with configurable depth levels
- **Candlestick/Kline Data**: OHLCV data for various timeframes
- **Symbol Information**: Tick size, minimum volume, and other symbol specifications

## Installation

### Step 1: Install the Expert Advisor

1. Copy `FlowsurfaceConnector.mq5` to your MetaTrader 5 data folder:
   - Open MetaTrader 5
   - Click **File** → **Open Data Folder**
   - Navigate to `MQL5/Experts/`
   - Paste the `FlowsurfaceConnector.mq5` file
   
2. Compile the Expert Advisor:
   - In MetaTrader 5, open **MetaEditor** (F4 or Tools → MetaQuotes Language Editor)
   - Open `FlowsurfaceConnector.mq5`
   - Click **Compile** or press F7
   - Ensure there are no errors

### Step 2: Enable Socket Connections

MetaTrader 5 requires explicit permission to create socket connections:

1. Open MetaTrader 5
2. Go to **Tools** → **Options** (or press Ctrl+O)
3. Navigate to the **Expert Advisors** tab
4. Check the option: **Allow DLL imports**
5. Check the option: **Allow WebRequest for listed URL**
6. Add `127.0.0.1` to the allowed URLs list
7. Click **OK**

### Step 3: Run Flowsurface

Start the Flowsurface application. The MetaTrader 5 adapter will listen for connections on port 7878 by default.

```bash
cargo run --release
```

### Step 4: Attach the EA to a Chart

1. In MetaTrader 5, open a chart for the symbol you want to monitor (e.g., XAUUSD)
2. In the **Navigator** panel, expand **Expert Advisors**
3. Drag `FlowsurfaceConnector` onto the chart
4. In the EA settings dialog, you can configure:
   - **FlowsurfaceHost**: IP address of Flowsurface (default: 127.0.0.1)
   - **FlowsurfacePort**: Port number (default: 7878)
   - **DepthLevels**: Number of order book levels to send (default: 10)
   - **SendTrades**: Enable/disable trade data streaming
   - **SendDepth**: Enable/disable market depth streaming
   - **SendKlines**: Enable/disable candlestick data streaming
   - **UpdateIntervalMs**: Data update interval in milliseconds (default: 100)
5. Check **Allow live trading** (required for socket connections)
6. Click **OK**

## Supported Symbols

The connector works with any symbol available in your MetaTrader 5 terminal, including but not limited to:
- **Forex pairs**: EURUSD, GBPUSD, USDJPY, etc.
- **Metals**: XAUUSD (Gold), XAGUSD (Silver)
- **Indices**: US30, US100, US500, etc.
- **Cryptocurrencies**: BTCUSD, ETHUSD, etc. (if available from your broker)

## Data Protocol

The EA sends JSON-formatted messages over TCP, one message per line. Message types:

### Ticker Info
```json
{
  "type": "ticker_info",
  "symbol": "XAUUSD",
  "tick_size": 0.01,
  "min_qty": 0.01,
  "digits": 2
}
```

### Trade Data
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

### Market Depth
```json
{
  "type": "depth",
  "symbol": "XAUUSD",
  "time": 1703686800000,
  "bids": [[2045.50, 10.5], [2045.40, 8.2]],
  "asks": [[2045.60, 12.3], [2045.70, 9.1]]
}
```

### Kline Data
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

## Troubleshooting

### EA won't start
- Ensure **Allow DLL imports** is enabled in Tools → Options → Expert Advisors
- Check that Flowsurface is running and listening on the specified port
- Verify socket permissions are enabled for `127.0.0.1`

### No data appearing in Flowsurface
- Check the MT5 **Experts** tab in the Terminal window for error messages
- Ensure the symbol has active market data (chart is receiving ticks)
- For market depth, ensure your broker provides DOM (Depth of Market) data
- Verify the connection by checking if the EA shows "Successfully connected to Flowsurface"

### Connection drops frequently
- Increase the `UpdateIntervalMs` parameter to reduce network load
- Check your network connection and firewall settings
- Ensure Flowsurface hasn't crashed or restarted

## Features

- **Real-time streaming**: Sub-second latency for market data
- **Automatic reconnection**: EA will attempt to reconnect if the connection drops
- **Configurable update rate**: Adjust the data refresh interval based on your needs
- **Multiple symbols**: Run the EA on multiple charts to monitor different symbols
- **Market depth support**: Full order book data for footprint charts
- **Trade detection**: Real-time trade execution data

## Performance Tips

- **Reduce update interval** for less active symbols or if experiencing performance issues
- **Disable unused features** (e.g., if you don't need klines, set `SendKlines = false`)
- **Limit depth levels** to reduce data volume if full order book isn't needed

## System Requirements

- MetaTrader 5 build 3200 or higher
- Network connection to localhost
- Flowsurface application running on the same machine (or accessible over network)

## Security Note

The default configuration connects to `localhost` (127.0.0.1), which is safe and doesn't expose your system to external connections. If you need to connect to Flowsurface running on a different machine, ensure proper firewall rules and network security measures are in place.
