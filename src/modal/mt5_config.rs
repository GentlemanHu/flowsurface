//! MT5 Connection Configuration Modal
//!
//! Allows users to configure MetaTrader 5 server connections
//! including server address, API credentials, and connection options.

use exchange::adapter::metatrader5::Mt5Config;
use iced::{
    Alignment, Element, Length,
    widget::{button, column, container, row, text, text_input, toggler},
};

use crate::style;

/// MT5 configuration modal messages
#[derive(Debug, Clone)]
pub enum Message {
    /// Server address changed
    ServerAddressChanged(String),
    /// API key changed
    ApiKeyChanged(String),
    /// API secret changed
    ApiSecretChanged(String),
    /// TLS toggle changed
    UseTlsChanged(bool),
    /// Auto reconnect toggle changed
    AutoReconnectChanged(bool),
    /// Test connection button pressed
    TestConnection,
    /// Save configuration
    Save,
    /// Cancel/close modal
    Cancel,
}

/// Actions returned from modal update
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// Save the configuration
    SaveConfig(Mt5Config),
    /// Test connection with current config
    TestConnection(Mt5Config),
    /// Close the modal
    Exit,
    /// No action
    None,
}

/// Connection test status
#[derive(Debug, Clone, Default)]
pub enum TestStatus {
    #[default]
    Idle,
    Testing,
    Success(String),
    Failed(String),
}

/// MT5 Configuration Modal state
pub struct Mt5ConfigModal {
    /// Current configuration being edited
    config: Mt5Config,
    /// Connection test status
    test_status: TestStatus,
    /// Whether this is a new connection or editing existing
    is_new: bool,
}

impl Mt5ConfigModal {
    /// Create a new configuration modal (for new connection)
    pub fn new() -> Self {
        Self {
            config: Mt5Config::default(),
            test_status: TestStatus::Idle,
            is_new: true,
        }
    }

    /// Update the modal state
    pub fn update(&mut self, message: Message) -> Action {
        match message {
            Message::ServerAddressChanged(addr) => {
                self.config.server_addr = addr;
                self.test_status = TestStatus::Idle;
                Action::None
            }
            Message::ApiKeyChanged(key) => {
                self.config.api_key = key;
                self.test_status = TestStatus::Idle;
                Action::None
            }
            Message::ApiSecretChanged(secret) => {
                self.config.api_secret = secret;
                self.test_status = TestStatus::Idle;
                Action::None
            }
            Message::UseTlsChanged(use_tls) => {
                self.config.use_tls = use_tls;
                self.test_status = TestStatus::Idle;
                Action::None
            }
            Message::AutoReconnectChanged(auto_reconnect) => {
                self.config.auto_reconnect = auto_reconnect;
                Action::None
            }
            Message::TestConnection => {
                self.test_status = TestStatus::Testing;
                Action::TestConnection(self.config.clone())
            }
            Message::ConnectionTestResult(success, msg) => {
                self.test_status = if success {
                    TestStatus::Success(msg)
                } else {
                    TestStatus::Failed(msg)
                };
                Action::None
            }
            Message::Save => {
                if let Err(e) = self.config.validate() {
                    self.test_status = TestStatus::Failed(e);
                    Action::None
                } else {
                    Action::SaveConfig(self.config.clone())
                }
            }
            Message::Cancel => Action::Exit,
        }
    }

    /// Render the modal view
    pub fn view(&self) -> Element<'_, Message> {
        let title = text(if self.is_new {
            "Add MT5 Connection"
        } else {
            "Edit MT5 Connection"
        })
        .size(18);

        // Server address input
        let server_input = labeled_input(
            "Server Address",
            "e.g., 192.168.1.100:9876",
            &self.config.server_addr,
            Message::ServerAddressChanged,
        );

        // API Key input
        let api_key_input = labeled_input(
            "API Key",
            "Your API key",
            &self.config.api_key,
            Message::ApiKeyChanged,
        );

        // API Secret input (password style)
        let api_secret_input = labeled_password_input(
            "API Secret",
            "Your API secret",
            &self.config.api_secret,
            Message::ApiSecretChanged,
        );

        // TLS toggle
        let tls_toggle = row![
            text("Use TLS (Recommended)").width(Length::Fill),
            toggler(self.config.use_tls)
                .on_toggle(Message::UseTlsChanged)
                .size(20),
        ]
        .align_y(Alignment::Center)
        .spacing(8);

        // Auto reconnect toggle
        let reconnect_toggle = row![
            text("Auto Reconnect").width(Length::Fill),
            toggler(self.config.auto_reconnect)
                .on_toggle(Message::AutoReconnectChanged)
                .size(20),
        ]
        .align_y(Alignment::Center)
        .spacing(8);

        // Test status display
        let test_status = match &self.test_status {
            TestStatus::Idle => text("").size(12),
            TestStatus::Testing => text("Testing connection...").size(12),
            TestStatus::Success(msg) => text(format!("✓ {}", msg))
                .size(12)
                .color(iced::Color::from_rgb(0.2, 0.8, 0.2)),
            TestStatus::Failed(msg) => text(format!("✗ {}", msg))
                .size(12)
                .color(iced::Color::from_rgb(0.9, 0.3, 0.3)),
        };

        // Buttons
        let test_btn = button(text("Test Connection").size(13))
            .on_press(Message::TestConnection)
            .style(button::secondary);

        let cancel_btn = button(text("Cancel").size(13))
            .on_press(Message::Cancel)
            .style(button::secondary);

        let save_btn = button(text("Save").size(13))
            .on_press(Message::Save)
            .style(button::primary);

        let buttons = row![
            test_btn,
            iced::widget::Space::new().width(Length::Fill),
            cancel_btn,
            save_btn,
        ]
        .spacing(8)
        .align_y(Alignment::Center);

        let content = column![
            title,
            iced::widget::Space::new().height(16),
            server_input,
            api_key_input,
            api_secret_input,
            iced::widget::Space::new().height(8),
            tls_toggle,
            reconnect_toggle,
            iced::widget::Space::new().height(8),
            test_status,
            iced::widget::Space::new().height(16),
            buttons,
        ]
        .spacing(12)
        .max_width(400);

        container(content)
            .padding(24)
            .style(style::dashboard_modal)
            .into()
    }
}

impl Default for Mt5ConfigModal {
    fn default() -> Self {
        Self::new()
    }
}

/// Helper: Create a labeled text input
fn labeled_input<'a>(
    label: &'a str,
    placeholder: &'a str,
    value: &'a str,
    on_input: impl Fn(String) -> Message + 'a,
) -> Element<'a, Message> {
    column![
        text(label).size(13),
        text_input(placeholder, value)
            .on_input(on_input)
            .padding(8)
            .size(14),
    ]
    .spacing(4)
    .into()
}

/// Helper: Create a labeled password input
fn labeled_password_input<'a>(
    label: &'a str,
    placeholder: &'a str,
    value: &'a str,
    on_input: impl Fn(String) -> Message + 'a,
) -> Element<'a, Message> {
    column![
        text(label).size(13),
        text_input(placeholder, value)
            .on_input(on_input)
            .secure(true)
            .padding(8)
            .size(14),
    ]
    .spacing(4)
    .into()
}
