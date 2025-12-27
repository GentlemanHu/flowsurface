# Flowsurface Architecture

## Overview

Flowsurface is a desktop charting application built with Rust and the iced GUI framework. It supports multiple data sources including cryptocurrency exchanges and MetaTrader 5.

## System Architecture

### Core Components

1. **GUI Layer** (`src/`)
   - Built with iced framework
   - Multi-window support
   - Real-time chart rendering
   - Interactive pane management

2. **Data Layer** (`data/`)
   - Configuration management
   - State persistence
   - Market data structures

3. **Exchange Layer** (`exchange/`)
   - WebSocket connections to exchanges
   - REST API integrations
   - Market data normalization

### MetaTrader 5 Integration Architecture

The MT5 integration uses a **client-server architecture** where:

- **Flowsurface acts as the SERVER**
  - Listens on TCP port 7878 (default)
  - Accepts connections from multiple MT5 clients
  - Processes and displays market data from all connected clients

- **MT5 Expert Advisor acts as the CLIENT**
  - Connects to Flowsurface server
  - Streams market data over TCP
  - Can run on multiple charts/symbols simultaneously

```
┌─────────────────────────────────────────────────────┐
│                   Flowsurface                       │
│              (TCP Server - Port 7878)               │
│                                                     │
│  ┌───────────┐  ┌───────────┐  ┌───────────┐     │
│  │  Binance  │  │   Bybit   │  │    MT5    │     │
│  │ WebSocket │  │ WebSocket │  │  Adapter  │     │
│  └───────────┘  └───────────┘  └─────┬─────┘     │
│                                        │           │
└────────────────────────────────────────┼───────────┘
                                         │
                    ┌────────────────────┼────────────────────┐
                    │                    │                    │
           ┌────────▼────────┐  ┌────────▼────────┐  ┌───────▼──────┐
           │  MT5 Terminal   │  │  MT5 Terminal   │  │ MT5 Terminal │
           │  (Client #1)    │  │  (Client #2)    │  │ (Client #3)  │
           │                 │  │                 │  │              │
           │  FlowsurfaceEA  │  │  FlowsurfaceEA  │  │ FlowsurfaceEA│
           │   Symbol: XAUUSD│  │  Symbol: EURUSD │  │Symbol: BTCUSD│
           └─────────────────┘  └─────────────────┘  └──────────────┘
```

### Why This Architecture?

1. **Multiple Symbol Support**: Each MT5 chart can run the EA for different symbols
2. **Cross-Platform**: Flowsurface can run on any platform, while MT5 runs on Windows
3. **Centralized Display**: All data converges in Flowsurface for unified visualization
4. **Network Flexibility**: Supports both local (127.0.0.1) and network connections

### Cross-Platform Connection

The current architecture already supports cross-platform connections:

- **Same Machine**: MT5 on Windows connects to Flowsurface on Windows (127.0.0.1)
- **Network Connection**: MT5 on one machine connects to Flowsurface on another
  - Example: MT5 on Windows PC → Flowsurface on Mac/Linux over LAN
  - Configure `FlowsurfaceHost` in EA settings to the IP address of the machine running Flowsurface
  - Ensure firewall allows incoming connections on port 7878

### Data Flow

1. **MT5 → Flowsurface**:
   ```
   MT5 Market Data → EA processes → JSON over TCP → Flowsurface receives → Chart updates
   ```

2. **Exchange → Flowsurface**:
   ```
   Exchange WebSocket → Market data → Internal processing → Chart updates
   ```

### Communication Protocol

The MT5 EA sends newline-delimited JSON messages:

- **Ticker Info**: Symbol specifications (tick size, min quantity)
- **Trade Data**: Individual trades with price, volume, direction
- **Market Depth**: Order book snapshots (bids/asks)
- **Kline Data**: OHLCV candlestick data

See [mql5/README.md](../mql5/README.md) for detailed protocol documentation.

## Configuration

### Flowsurface Settings

- Data directory: Platform-specific (use "Open data folder" in settings)
- State file: `saved-state.json` (persists layouts, themes, window positions)
- MT5 adapter: Automatically starts when Flowsurface launches

### MT5 EA Settings

Configurable in EA properties when attaching to a chart:

- `FlowsurfaceHost`: IP address (default: 127.0.0.1)
- `FlowsurfacePort`: TCP port (default: 7878)
- `DepthLevels`: Order book depth (default: 10)
- `SendTrades`: Enable trade streaming
- `SendDepth`: Enable order book streaming
- `SendKlines`: Enable candlestick streaming
- `UpdateIntervalMs`: Data refresh rate (default: 100ms)

## Building and Deployment

### Release Builds

Flowsurface uses GitHub Actions for automated builds:

- **Windows**: x86_64 and ARM64 (future)
- **macOS**: Universal binary (ARM + Intel)
- **Linux**: x86_64 and ARM64 packages

### Build Artifacts

Each release includes:
- Platform-specific executables
- SHA256 checksums
- Optional GPG signatures (if configured)

## Performance Considerations

### Memory Management

- Market data retention: Configurable per chart type
- Automatic cleanup of old data
- Efficient data structures for real-time updates

### Threading

- GUI runs on main thread
- WebSocket connections on separate threads
- MT5 TCP server on dedicated thread
- Market data processing uses async tasks

## Security

### Network Security

- MT5 connections default to localhost (127.0.0.1)
- Network connections require explicit configuration
- No authentication (designed for trusted networks)

### Data Privacy

- All data stored locally
- No telemetry or analytics
- Open source for auditability

## Troubleshooting

### MT5 Connection Issues

1. **EA won't connect**:
   - Verify Flowsurface is running
   - Check MT5 socket permissions (Tools → Options → Expert Advisors)
   - Confirm "Allow DLL imports" is enabled
   - Test with `telnet 127.0.0.1 7878`

2. **Cross-network connection fails**:
   - Check firewall on Flowsurface machine
   - Verify network connectivity (`ping` the IP)
   - Confirm correct IP in EA settings
   - Check if port 7878 is open

3. **Data not appearing**:
   - Verify symbol has active market data in MT5
   - Check MT5 Experts tab for error messages
   - Ensure broker provides required data (especially DOM/depth)

### Application Crashes

- Check `crash.log` in data folder (Windows release builds)
- Review `flowsurface.log` for runtime errors
- Report issues with log files on GitHub

## Future Enhancements

Potential architecture improvements:

- WebSocket API for external clients
- Plugin system for custom indicators
- Cloud synchronization for layouts/themes
- Multi-user support with authentication
