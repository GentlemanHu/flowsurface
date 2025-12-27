# Windows Executable Troubleshooting Guide

## Issue: Windows executable doesn't respond when clicked

If the Flowsurface executable on Windows shows no response or error when double-clicked, this guide will help you diagnose and fix the issue.

## Recent Changes (v0.8.6+)

Starting from version 0.8.6, the Windows release build includes enhanced error handling:

1. **Error Message Boxes**: If the application fails to start, a Windows message box will display the error
2. **Crash Logs**: Startup failures are automatically logged to `crash.log` in your data folder
3. **Panic Handler**: Unexpected crashes now show detailed error messages instead of silently failing

## Troubleshooting Steps

### Step 1: Check for Error Messages

When you run the executable:
- **If you see an error message box**: Read the error message and proceed to Step 3
- **If nothing happens**: The application might be failing silently (older version) or an error dialog might be hidden

### Step 2: Check the Crash Log

1. Open the data folder:
   - Press `Win + R` to open Run dialog
   - Type: `%APPDATA%\flowsurface` and press Enter
   - If the folder doesn't exist, try: `%LOCALAPPDATA%\flowsurface`

2. Look for `crash.log` or `flowsurface.log` files

3. Open these files with Notepad to see error details

### Step 3: Common Issues and Solutions

#### Missing DLL Files

**Error**: "The code execution cannot proceed because [DLL name] was not found"

**Solution**:
- Install [Microsoft Visual C++ Redistributable](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist)
- Download and install both x64 and x86 versions
- Restart your computer

#### Windows Defender / Antivirus Blocking

**Symptoms**: 
- Executable disappears after download
- "Windows protected your PC" message
- Antivirus quarantine notification

**Solution**:
1. Click "More info" on the Windows SmartScreen popup
2. Click "Run anyway"
3. Or add Flowsurface to your antivirus exceptions:
   - Windows Defender: Settings → Update & Security → Windows Security → Virus & threat protection → Manage settings → Add or remove exclusions
   - Add the Flowsurface executable location

#### Graphics Driver Issues

**Error**: "Failed to initialize graphics" or "WGPU error"

**Solution**:
1. Update your graphics drivers:
   - NVIDIA: [GeForce Experience](https://www.nvidia.com/en-us/geforce/geforce-experience/)
   - AMD: [AMD Software](https://www.amd.com/en/support)
   - Intel: [Intel Driver & Support Assistant](https://www.intel.com/content/www/us/en/support/detect.html)

2. If updating doesn't help, try running with software rendering:
   - Create a shortcut to the executable
   - Right-click → Properties
   - Add to the end of "Target": ` --software-renderer`
   - Click OK and run from the shortcut

#### Permission Issues

**Symptoms**: 
- "Access denied" errors
- Can't create data folder
- Can't write log files

**Solution**:
1. Run as Administrator (right-click → Run as administrator)
2. Move the executable to a user-writable location (not Program Files)
3. Check folder permissions

### Step 4: Run from Command Prompt

To see real-time error messages:

1. Open Command Prompt (cmd.exe)
2. Navigate to the folder containing flowsurface.exe:
   ```
   cd C:\path\to\flowsurface
   ```
3. Run the executable:
   ```
   flowsurface.exe
   ```
4. Watch for error messages in the console

### Step 5: Check System Requirements

Minimum requirements:
- **OS**: Windows 10 or later (64-bit)
- **RAM**: 2 GB minimum, 4 GB recommended
- **Graphics**: DirectX 11 compatible graphics card
- **Disk Space**: 100 MB for application + space for market data

## Debug Build

For detailed debugging, you can build a debug version yourself:

1. Install [Rust](https://rustup.rs/)
2. Clone the repository:
   ```
   git clone https://github.com/flowsurface-rs/flowsurface
   cd flowsurface
   ```
3. Build and run in debug mode:
   ```
   cargo run
   ```

Debug builds show a console window with detailed logs.

## Reporting Issues

If none of the above solutions work, please report the issue on GitHub:

1. Go to https://github.com/flowsurface-rs/flowsurface/issues
2. Click "New Issue"
3. Include:
   - Windows version (run `winver` to check)
   - Contents of `crash.log` if available
   - Screenshot of any error messages
   - Steps you've already tried

## Known Issues

### Windows 11 ARM

The application is built for x86_64 and runs under emulation on Windows 11 ARM devices. Performance may vary.

### High DPI Displays

If the UI appears too small or too large:
1. Launch Flowsurface
2. Open Settings (gear icon in sidebar)
3. Adjust "Interface scale" to your preference

### Antivirus False Positives

Unsigned executables may trigger false positives. This is expected for open-source software. The application:
- Does not collect telemetry
- Does not connect to unauthorized servers
- Only makes network requests to public exchange APIs and your local MT5 instance
- Is fully open source and auditable

## Additional Resources

- [Main Documentation](../README.md)
- [Architecture Overview](ARCHITECTURE.md)
- [MT5 Integration Guide](../mql5/README.md)
- [GitHub Issues](https://github.com/flowsurface-rs/flowsurface/issues)

## Future Improvements

We are working on:
- Code signing certificates to eliminate SmartScreen warnings
- Installer package for easier deployment
- Better error reporting and diagnostics
- Automatic crash report submission (opt-in)
