---
description: Build MT5 proxy server for all platforms
---

# Build MT5 Proxy

This workflow builds the MT5 proxy server as a single binary for multiple platforms.

## Local Build

```bash
cd MT5Server/proxy

# Install dependencies
go mod tidy

# Build for current platform
go build -ldflags="-s -w" -o mt5-proxy

# Run
./mt5-proxy -port 9876 -key YOUR_API_KEY -secret YOUR_SECRET
```

## Cross-Platform Build

```bash
cd MT5Server/proxy

# Windows
GOOS=windows GOARCH=amd64 go build -ldflags="-s -w" -o mt5-proxy-windows-amd64.exe

# macOS Intel
GOOS=darwin GOARCH=amd64 go build -ldflags="-s -w" -o mt5-proxy-darwin-amd64

# macOS Apple Silicon
GOOS=darwin GOARCH=arm64 go build -ldflags="-s -w" -o mt5-proxy-darwin-arm64

# Linux
GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o mt5-proxy-linux-amd64
```

## GitHub Actions (Automatic)

Push a tag starting with `proxy-v` to trigger automatic builds:

```bash
git tag proxy-v1.0.0
git push origin proxy-v1.0.0
```

The workflow will build for all platforms and create a release.
