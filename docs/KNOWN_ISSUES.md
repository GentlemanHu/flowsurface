# Known Issues

## Windows Executable Startup Failures

### Problem
The Windows executable built by the release workflow may not start when double-clicked. The executable shows no error message, no window, and no logs.

### Current Status
- The build completes successfully
- Artifacts are generated
- macOS builds work correctly
- Linux builds work correctly
- Windows build does not start

### Possible Causes
1. **Missing Dependencies**: Windows runtime dependencies (Visual C++ redistributables, etc.)
2. **Graphics Driver Issues**: The application uses wgpu for GPU rendering, which may fail on some systems
3. **Panic on Startup**: Silent panic before any logging is initialized
4. **Windows Subsystem Configuration**: The app is configured as a GUI app (`windows_subsystem = "windows"`), which hides console output

### Debugging Steps

If you encounter this issue:

1. **Try running from Command Line**:
   ```cmd
   flowsurface.exe
   ```
   This may show error messages that are hidden when double-clicking.

2. **Check Dependencies**:
   - Install the latest Visual C++ Redistributables
   - Update graphics drivers
   - Ensure .NET Framework is installed (if needed by dependencies)

3. **Check Logs**:
   The application logs to the data folder. Look for:
   - Windows: `%APPDATA%\flowsurface\logs\`
   - Crash dumps or initialization errors

4. **Build from Source**:
   As a workaround, build the application locally:
   ```powershell
   git clone https://github.com/flowsurface-rs/flowsurface
   cd flowsurface
   cargo build --release
   cargo run --release
   ```
   
   Building from source ensures all dependencies are correctly linked for your system.

### Potential Solutions to Investigate

1. **Add Panic Handler for Windows**:
   ```rust
   #[cfg(all(windows, not(debug_assertions)))]
   fn setup_panic_handler() {
       std::panic::set_hook(Box::new(|panic_info| {
           use std::io::Write;
           let msg = format!("Application panicked: {:?}", panic_info);
           if let Ok(mut file) = std::fs::File::create("crash.log") {
               let _ = file.write_all(msg.as_bytes());
           }
       }));
   }
   ```

2. **Add Startup Logging**:
   Log immediately on startup before any initialization:
   ```rust
   #[cfg(windows)]
   fn log_startup() {
       let log_path = std::env::temp_dir().join("flowsurface_startup.log");
       let _ = std::fs::write(&log_path, format!("Started at {:?}", std::time::SystemTime::now()));
   }
   ```

3. **Test with Console Window**:
   Temporarily remove the windows_subsystem attribute to see console output:
   ```rust
   // Comment out this line for debugging:
   // #![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
   ```

4. **Static Linking**:
   Ensure the Windows build uses static linking:
   ```toml
   [target.x86_64-pc-windows-msvc]
   rustflags = ["-C", "target-feature=+crt-static"]
   ```

### Workarounds

**Immediate Workaround**: Build from source as shown above.

**For Users**: 
- Download the macOS or Linux version if you have access to those platforms
- Use WSL2 on Windows to run the Linux version
- Wait for a fix in the next release

### Contributing

If you have a Windows machine and can help debug this issue:
1. Clone the repository
2. Try running with debug symbols: `cargo run`
3. If it works, try release mode: `cargo run --release`
4. Report your findings in a GitHub issue

### Related Issues
- Build succeeds but executable doesn't start
- No error messages or logs
- macOS and Linux builds work correctly

### Status
**Open** - Needs investigation and testing on Windows machines.
