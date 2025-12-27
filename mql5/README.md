# MetaTrader 5 Integration for Flowsurface

This directory contains the MQL5 Expert Advisor (EA) that enables MetaTrader 5 to provide market data to Flowsurface.

## Overview

The Flowsurface Connector EA creates a TCP server in MetaTrader 5 and waits for Flowsurface to connect as a client. This architecture enables:
- **Remote connections**: Connect to MT5 running on a different machine (e.g., VPS)
- **Multiple instances**: Run MT5 on one machine and Flowsurface on another
- **Flexible deployment**: Connect from anywhere on your network

The EA streams real-time market data including:
- **Trade Data**: Individual trades with price, volume, and direction
- **Market Depth**: Order book data with configurable depth levels
- **Candlestick/Kline Data**: OHLCV data for various timeframes
- **Symbol Information**: Tick size, minimum volume, and other symbol specifications

## Architecture

```
┌─────────────────┐                    ┌──────────────────┐
│   MetaTrader 5  │                    │   Flowsurface    │
│                 │                    │                  │
│  FlowsurfaceEA  │ ◄──TCP Server──── │  MT5 Adapter     │
│  (Port 7878)    │    (Port 7878)     │  (TCP Client)    │
└─────────────────┘                    └──────────────────┘
      Server                                  Client
   (Data Provider)                      (Data Consumer)
```

**Key Change**: MQL5 now acts as the **server** (listens for connections), and Flowsurface acts as the **client** (connects to MQL5). This enables remote connections across networks.

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
5. Click **OK**

**Note**: Since MT5 now acts as a server, there's no need to add URLs to the WebRequest whitelist.

### Step 3: Configure Firewall (for Remote Connections)

If you want to connect to MT5 from a different machine:

1. Open port 7878 (or your chosen port) in your firewall
2. On Windows: Windows Defender Firewall → Advanced Settings → Inbound Rules → New Rule
3. Choose Port → TCP → Specific port (7878) → Allow the connection
4. Make sure your VPS/server security group also allows this port

**Security Warning**: Only open firewall ports when necessary. Consider using VPN or SSH tunneling for production use.

### Step 4: Attach the EA to a Chart

1. In MetaTrader 5, open a chart for the symbol you want to monitor (e.g., XAUUSD)
2. In the **Navigator** panel, expand **Expert Advisors**
3. Drag `FlowsurfaceConnector` onto the chart
4. In the EA settings dialog, you can configure:
   - **ServerPort**: Port number for the TCP server (default: 7878)
   - **DepthLevels**: Number of order book levels to send (default: 10)
   - **SendTrades**: Enable/disable trade data streaming
   - **SendDepth**: Enable/disable market depth streaming
   - **SendKlines**: Enable/disable candlestick data streaming
   - **UpdateIntervalMs**: Data update interval in milliseconds (default: 100)
5. Check **Allow live trading** (required for socket connections)
6. Click **OK**

The EA will start a TCP server and wait for Flowsurface to connect.

### Step 5: Configure Flowsurface to Connect

When adding a MetaTrader 5 ticker in Flowsurface:

1. Select **MetaTrader5** as the exchange
2. Enter the symbol name (e.g., `XAUUSD`)
3. Configure connection settings:
   - **Host**: IP address of the machine running MT5
     - Use `127.0.0.1` or `localhost` if MT5 is on the same machine
     - Use the LAN IP (e.g., `192.168.1.100`) for local network connections
     - Use the public IP or domain for remote/VPS connections
   - **Port**: Must match the `ServerPort` in the EA (default: 7878)
4. Click **Connect**

Flowsurface will connect to the MT5 server and start receiving market data.

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
- Check that port 7878 (or your chosen port) is not already in use
- Verify that another EA or application isn't using the same port

### Flowsurface can't connect
- Check that the MT5 EA is running (you should see "TCP server started successfully" in the Experts tab)
- Verify the host and port settings in Flowsurface match the EA configuration
- For remote connections:
  - Ensure firewall allows incoming connections on the specified port
  - Check network connectivity between machines
  - Verify VPS/server security group settings
- Test local connection first (127.0.0.1) before trying remote connections

### No data appearing in Flowsurface
- Check the MT5 **Experts** tab in the Terminal window for error messages
- Ensure the symbol has active market data (chart is receiving ticks)
- For market depth, ensure your broker provides DOM (Depth of Market) data
- Verify the EA shows "Flowsurface client connected!" after Flowsurface connects

### Connection drops frequently
- Increase the `UpdateIntervalMs` parameter to reduce network load
- Check your network connection stability
- For remote connections, consider network latency and bandwidth
- Monitor MT5 Experts log for disconnection messages

## Features

- **Remote connections**: Connect to MT5 running anywhere on your network or VPS
- **Real-time streaming**: Sub-second latency for market data
- **Automatic reconnection**: Flowsurface can reconnect if the connection drops
- **Configurable update rate**: Adjust the data refresh interval based on your needs
- **Multiple symbols**: Run the EA on multiple charts to monitor different symbols simultaneously
- **Market depth support**: Full order book data for footprint charts
- **Trade detection**: Real-time trade execution data

## Remote Connection Examples

### Local Connection (Same Machine)
- MT5 and Flowsurface on the same computer
- Host: `127.0.0.1` or `localhost`
- Port: `7878` (default)

### LAN Connection
- MT5 on desktop, Flowsurface on laptop (same network)
- Host: Local IP of MT5 machine (e.g., `192.168.1.100`)
- Port: `7878` (default)
- Ensure firewall allows the connection

### Remote/VPS Connection
- MT5 on VPS, Flowsurface on local machine
- Host: Public IP or domain of VPS (e.g., `203.0.113.10` or `mt5.example.com`)
- Port: `7878` (default, or custom port)
- Configure VPS firewall and security group
- **Recommended**: Use VPN or SSH tunnel for secure connections

## Performance Tips

- **Reduce update interval** for less active symbols or if experiencing performance issues
- **Disable unused features** (e.g., if you don't need klines, set `SendKlines = false`)
- **Limit depth levels** to reduce data volume if full order book isn't needed

## System Requirements

- MetaTrader 5 build 3200 or higher
- Network connection to localhost
- Flowsurface application running on the same machine (or accessible over network)

## Security Note

The default configuration accepts connections from any IP address on the specified port. 

**For local use**: This is safe when MT5 and Flowsurface are on the same machine.

**For network/remote use**: 
- Ensure proper firewall configuration
- Only open necessary ports
- Consider these security measures:
  1. Use a VPN for connections over the internet
  2. Set up SSH tunneling for encrypted connections
  3. Restrict firewall rules to specific IP addresses
  4. Use a non-standard port to reduce exposure
  5. Monitor connection logs in MT5 Experts tab

**Example SSH Tunnel** (for advanced users):
```bash
# On local machine, forward local port 7878 to VPS port 7878
ssh -L 7878:localhost:7878 user@vps-ip

# Then connect Flowsurface to localhost:7878
```
