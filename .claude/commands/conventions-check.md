# Conventions Check — Coding Standards Scan

Scan recently changed Swift files for coding convention violations. Run this before committing.

## Step 1: Identify Changed Files

Run `git diff --name-only HEAD` and filter for `.swift` files under `Whisperer/`.

If no Swift files changed, report "No Swift files changed — nothing to check" and stop.

## Step 2: Load Coding Conventions

Read `AGENTS.md` for the coding conventions reference.

## Step 3: Scan Each Changed File

For each changed Swift file, check for these violations:

### Logging Violations
- [ ] `print(` statements (should be `Logger.debug/info/warning/error()` with appropriate subsystem)
  - Exception: `#if DEBUG` blocks may use `print()` for console output

### Memory Safety Violations
- [ ] `Task {` or `Task.detached {` without `[weak self]` (strong capture creates retain cycles)
- [ ] Non-weak delegate properties (`var delegate: SomeDelegate?` should be `weak var delegate: SomeDelegate?`)
- [ ] NotificationCenter observers added without corresponding removal in `deinit`

### Swift Safety Violations
- [ ] Force unwraps (`!`) outside of `guard` + `fatalError` patterns (should use optional chaining or `guard let`)
  - Exception: `@IBOutlet` and known-safe patterns like `Bundle.main.infoDictionary!`

### Error Handling Violations
- [ ] Errors logged without subsystem (should be `Logger.error("msg", subsystem: .appropriate)`)
- [ ] `try!` or `try?` without explanation (should handle errors explicitly or document why force/optional try is safe)

### Threading Violations
- [ ] Direct mutation of `AppState` properties from background threads (must use `await MainActor.run { }`)
- [ ] `DispatchQueue.main.sync` calls (potential deadlock if already on main thread)

## Step 4: Report

For each violation found, report:
- File path and line number
- What was found
- The recommended fix

If no violations found, report "Conventions check passed — no violations found."
