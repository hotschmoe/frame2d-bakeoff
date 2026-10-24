# Agent session transcripts (run1, win-arm64)

Raw Claude Code subagent transcripts (JSONL, xz-compressed: `xz -dk <file>.jsonl.xz`), one per agent run, copied from the orchestrator session when each
run finished. Source for the SPEC 8.1 metrics (turns, tool calls, builds, failure taxonomy).
`<name>.meta.json` is the agent's metadata. The user's email in injected context is redacted as `<user-email>`.

| file | run |
|------|-----|
| zig-dvui-smoke | SPEC 15.6 dvui smoke test (not scored) |
| <stack>-P1 / -P2 / -P3 | that stack's phase |
