use super::ScaleFactor;
use super::sidebar::Sidebar;
use super::timezone::UserTimezone;
use crate::layout::WindowSpec;
use crate::{AudioStream, Layout, Theme};

use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize, Default)]
pub struct Layouts {
    pub layouts: Vec<Layout>,
    pub active_layout: Option<String>,
}

/// MT5 connection configuration for persistence
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Mt5Connection {
    /// Display name for this connection
    pub name: String,
    /// Server address (host:port)
    pub server_addr: String,
    /// API key for authentication
    pub api_key: String,
    /// Whether to use TLS
    pub use_tls: bool,
    /// Auto reconnect on disconnect
    pub auto_reconnect: bool,
}

/// MT5 settings - stores all MT5 connections
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Mt5Settings {
    /// List of configured MT5 connections
    pub connections: Vec<Mt5Connection>,
    /// Active connection name (if any)
    pub active_connection: Option<String>,
}

#[derive(Default, Clone, Deserialize, Serialize)]
#[serde(default)]
pub struct State {
    pub layout_manager: Layouts,
    pub selected_theme: Theme,
    pub custom_theme: Option<Theme>,
    pub main_window: Option<WindowSpec>,
    pub timezone: UserTimezone,
    pub sidebar: Sidebar,
    pub scale_factor: ScaleFactor,
    pub audio_cfg: AudioStream,
    pub trade_fetch_enabled: bool,
    pub size_in_quote_ccy: exchange::SizeUnit,
    /// MT5 connection settings
    pub mt5_settings: Mt5Settings,
}

impl State {
    pub fn from_parts(
        layout_manager: Layouts,
        selected_theme: Theme,
        custom_theme: Option<Theme>,
        main_window: Option<WindowSpec>,
        timezone: UserTimezone,
        sidebar: Sidebar,
        scale_factor: ScaleFactor,
        audio_cfg: AudioStream,
        volume_size_unit: exchange::SizeUnit,
    ) -> Self {
        State {
            layout_manager,
            selected_theme: Theme(selected_theme.0),
            custom_theme: custom_theme.map(|t| Theme(t.0)),
            main_window,
            timezone,
            sidebar,
            scale_factor,
            audio_cfg,
            trade_fetch_enabled: exchange::fetcher::is_trade_fetch_enabled(),
            size_in_quote_ccy: volume_size_unit,
            mt5_settings: Mt5Settings::default(),
        }
    }
}
