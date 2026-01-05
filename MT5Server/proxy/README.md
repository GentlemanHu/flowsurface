# MT5 Proxy Server

WebSocket 代理服务器，桥接 MT5 EA 和 Flowsurface 桌面应用。

**单二进制，无依赖，开箱即用。**

## 下载

从 [Releases](../../releases) 下载对应平台的二进制文件：

| 平台 | 文件 |
|------|------|
| Windows x64 | `mt5-proxy-windows-amd64.exe` |
| macOS Intel | `mt5-proxy-darwin-amd64` |
| macOS Apple Silicon | `mt5-proxy-darwin-arm64` |
| Linux x64 | `mt5-proxy-linux-amd64` |

## 使用

```bash
# 基本启动
./mt5-proxy

# 自定义配置
./mt5-proxy -port 9876 -key your_api_key -secret your_secret

# 使用环境变量
export API_KEY=your_api_key
export API_SECRET=your_secret
./mt5-proxy
```

## 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `-port` | 9876 | 服务器端口 |
| `-key` | your_api_key | API 密钥 |
| `-secret` | your_secret | API 密钥 |
| `-tolerance` | 30000 | 时间戳容差（毫秒） |

## 端点

| 端点 | 用途 |
|------|------|
| `ws://host:port/mt5` | MT5 EA 连接 |
| `ws://host:port/client` | Flowsurface 客户端连接 |

## 编译

```bash
# 安装依赖
go mod tidy

# 编译当前平台
go build -o mt5-proxy

# 跨平台编译
GOOS=windows GOARCH=amd64 go build -o mt5-proxy.exe
GOOS=darwin GOARCH=arm64 go build -o mt5-proxy-darwin-arm64
GOOS=linux GOARCH=amd64 go build -o mt5-proxy-linux-amd64
```
