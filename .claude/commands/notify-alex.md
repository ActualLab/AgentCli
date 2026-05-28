---
allowed-tools: mcp__voxt-robokitty__post_message, Read
description: Send a notification to Alex Yakunin via the RoboKitty bot's direct (peer) chat with him. Use for alerts, run results, or anything that needs to reach Alex out-of-band. Supports reading the message from a file.
argument-hint: [--file <path>] [message...]
---

# Notify Alex

Post a single message to **Alex Yakunin's direct (peer) chat** with the
RoboKitty bot, using `mcp__voxt-robokitty__post_message`. This is the
out-of-band channel for alerting Alex — e.g. a scheduled job failed, a run
finished, or something needs his attention.

The target is **fixed**:

| Field | Value |
|-------|-------|
| MCP | `voxt-robokitty` |
| Chat | peer chat with Alex Yakunin |
| chatId | `p-hjp639qb6bp1-sK7lu2` |

There is no chat-selection step — always post to `p-hjp639qb6bp1-sK7lu2`.

## Arguments

`$ARGUMENTS` is the message, with one optional flag:

- `--file <path>` — read the message text from the given file (UTF-8, full
  contents, trim only a single trailing newline). When `--file` is provided,
  any remaining positional words are ignored (warn if non-empty).

If `--file` is not given, the message is the whole of `$ARGUMENTS` (after
removing the flag if present). Preserve internal whitespace; trim only
leading/trailing whitespace of the whole message. The message need not be
quoted — the user often writes it bare:

```
/notify-alex notes-enrich: chrome-devtools-1 was down, skipped link summaries this run.
/notify-alex --file /proj/Cowork/tmp/alert.md
```

## Posting

- Pass the message text through **verbatim** — do not strip, re-escape, or
  "improve" markup (markdown, code fences, URLs, mentions). Do not add a
  prefix/suffix or signature unless the user typed it.
- Call `mcp__voxt-robokitty__post_message` with
  `chatId = "p-hjp639qb6bp1-sK7lu2"` and the resolved `text`.
- On success, report the returned local id in one short line: `Notified Alex (LID: <id>).`
- On failure, surface the error verbatim and do not retry automatically.
- If the message is empty after trimming, stop and say so — do not post an
  empty message.

This command posts immediately — treat it as a user-visible action.

Arguments: $ARGUMENTS
