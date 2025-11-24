# AGENTS NOTES

## Hardware / Platform
- Target device is ESP32 running AtomVM; not all Elixir/Erlang standard modules are available (e.g., `Float`, `String` modules are missing).
- SPI transfer time for 60 WS2812-style LEDs is roughly 1–2 ms per frame with current driver.
- AtomVM task watchdog trips quickly when a process hogs the scheduler; long-running SPI writes or tight timers must yield.

## LED Server (`avm_ls_server`)
- `fill/1` is synchronous (`gen_server:call/2`) and blocks the caller until SPI flush completes.
- `fill_async/1` uses `cast/2` to avoid blocking but can flood the mailbox; keep updates infrequent or ensure server throttles flushes.
- `flush_pending` flag is used to mark dirty frames; sending redundant flush messages causes unnecessary work.
- Periodic timer-based flushing is tricky because `collect_dirty_leds` + `spi:write/3` can exceed watchdog deadlines; prefer event-driven flushes unless throttled carefully.

## Breath Effect Learnings (`lib/avm_ls.ex`)
- Use absolute phase derivation (`advance_phase/3`) instead of cumulative increments to avoid drift.
- Gamma-corrected lookup table with interpolation is cheaper than per-tick trig and gives smoother easing.
- Low-pass filtering (`@lowpass_alpha`) blends brightness updates and hides scheduler jitter.
- Brightness thresholds (`@min_brightness_step`) reduce redundant updates but can cause stepping if set too high.
- Instrumentation hooks (`@instrument?`, `log_instrument/2`) are invaluable for spotting bottlenecks; prefer `:erlang.monotonic_time(:microsecond)` for accurate timings.

## Debugging Tips
- Watchdog errors often mean the server loop is spending >~10 ms without yielding; inspect timers and SPI workloads when this happens.
- When adding trig or math helpers, verify the target AtomVM build supports the modules; fall back to `:erlang` BIFs when in doubt.
- Use `fill_async` sparingly; uncontrolled casts can inflate the mailbox even if each flush is fast.

---
These notes capture the main constraints and heuristics discovered so far; future agents can extend them as the architecture evolves.
