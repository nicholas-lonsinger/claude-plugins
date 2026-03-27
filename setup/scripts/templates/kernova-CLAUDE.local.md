## Sandbox

All `xcodebuild` commands (build and test) must use `dangerouslyDisableSandbox: true` on the Bash tool. The sandbox blocks Mach XPC services (`swift-plugin-server`, `testmanagerd`) that the Swift compiler and test runner need for IPC, causing `ObservableMacro` build failures and test runner connection errors.

## Post-Build

After every successful build, copy the binary to `/Volumes/My Shared Files/Kernova/` with an epoch-timestamped filename. Capture the name in a variable so it can be reported:

```bash
BUILD_NAME="Kernova-$(date +%s).app"
ditto --noextattr DerivedData/Build/Products/Debug/Kernova.app "/Volumes/My Shared Files/Kernova/$BUILD_NAME"
```

Each build gets a unique name (e.g., `Kernova-1742598000.app`) so copies never conflict with a locked running app. The highest number is always the latest build.

This step is **mandatory** — always run it after a successful `xcodebuild build`.

### Reporting the build artifact

After the copy, always include the artifact name in the response:

- If **Maintenance Notes** are present (from Architecture Change Protocol), append it as the last line item:
  ```
  ### Maintenance Notes
  - ✅ ...
  - 📦 Build artifact: `Kernova-1742598000.app`
  ```
- If Maintenance Notes are **not** shown, state it standalone:
  ```
  📦 Build artifact: `Kernova-1742598000.app`
  ```
