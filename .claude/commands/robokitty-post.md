---
allowed-tools: mcp__voxt-robokitty__post_message, mcp__voxt-robokitty__list_group_chats, mcp__voxt-robokitty__list_peer_chats, mcp__voxt-robokitty__list_place_chats, mcp__voxt-robokitty__list_places, Read
description: Post a message to a Voxt (RoboKitty) chat by chat id or by chat title. Supports reading the message from a file. Markup in the message is preserved verbatim.
argument-hint: (--chatId <id> | --chat "<Title>") [--file <path>] [message...]
---

# Post a message to a Voxt (RoboKitty) chat

Parse `$ARGUMENTS` and post a single text message to the target chat using `mcp__voxt-robokitty__post_message`. Do not strip, re-escape, or "improve" the message text — markup (markdown, code fences, mentions, URLs) must be passed through verbatim.

## Arguments

Exactly one **target** flag is required:

- `--chatId <chatId>` — post directly. Example id: `s-pmMsV1UVKG-xigkwj28ql`.
- `--chat "<Chat Title>"` — resolve title → chat id (see "Resolving a title" below).

Optional **message source** flag:

- `--file <path>` — read the message text from the given file (UTF-8, full contents, trailing newline trimmed). When `--file` is provided, any remaining positional words after the flags are ignored (warn if non-empty).

If `--file` is **not** provided, the message is the rest of `$ARGUMENTS` after the target flag and its value. Preserve internal whitespace; only trim leading/trailing whitespace of the whole message. Do **not** require the message to be quoted — the user often writes it bare, e.g.:

```
/robokitty-post --chatId s-pmMsV1UVKG-xigkwj28ql Hey, hello from Claude Code!
/robokitty-post --chat "Standup" Hey, **hello** from Claude Code!
/robokitty-post --chat "Standup" --file /proj/ActualChat/tmp/announcement.md
```

If neither `--chatId` nor `--chat` is given, or if both are given, **stop and ask** which one the user meant. Do not guess.

## Resolving a title

When `--chat "<Title>"` is used, **first** check the known-chats table below (place **Actual Chat**, id `pmMsV1UVKG`) — match `title` **case-insensitively, exact match**. If found, use that id directly without calling any list tool.

### Known chats in place "Actual Chat" (`pmMsV1UVKG`)

| Title | chatId |
|---|---|
| UI | `s-pmMsV1UVKG-4grxv25yrt` |
| Growth Ideas | `s-pmMsV1UVKG-6I4EygQEkF` |
| Marketing | `s-pmMsV1UVKG-BXBQA1S2AB` |
| Releases | `s-pmMsV1UVKG-dCKQXnYpX9` |
| Bugs (Mobile) | `s-pmMsV1UVKG-fPHVtB5Zz0` |
| Development | `s-pmMsV1UVKG-gp3lr3p96e` |
| Dev \| Voice | `s-pmMsV1UVKG-gq3scl6uhd` |
| Review Requests | `s-pmMsV1UVKG-gz3ymbh6n3` |
| Coding Style | `s-pmMsV1UVKG-kca65adeh3` |
| ML | `s-pmMsV1UVKG-klg7MeJODe` |
| Important | `s-pmMsV1UVKG-o1xwow0b82` |
| Design | `s-pmMsV1UVKG-pybxohlnd9` |
| Bugs | `s-pmMsV1UVKG-v3m8jr8kuj` |
| General / Всякое разное | `s-pmMsV1UVKG-welcome` |
| Standup | `s-pmMsV1UVKG-xigkwj28ql` |
| iOS-specific | `s-pmMsV1UVKG-zZyNyZqSL3` |

This table is a snapshot and may go stale (chats can be renamed, added, or removed).

### Fallback search (when the title is not in the table above)

If the requested title is **not** in the table, you **must** look it up by listing chats. Search in this order and stop at the first exact (case-insensitive) match:

1. `mcp__voxt-robokitty__list_place_chats` for place `pmMsV1UVKG` (the **Actual Chat** place — most likely target; page with `afterId` until exhausted).
2. `mcp__voxt-robokitty__list_places` → for every other place, `mcp__voxt-robokitty__list_place_chats` (same paging).
3. `mcp__voxt-robokitty__list_group_chats` (same paging).
4. `mcp__voxt-robokitty__list_peer_chats` (same paging).

Rules:
- If **no** chat matches after the fallback search, report the title and stop — do not post.
- If **multiple** chats match the same title across the searches, list them (id + which bucket / place they came from) and ask the user to pick. Do not post until disambiguated.
- Once resolved, briefly state the resolved chat id before posting (one line, e.g. `Resolved "Standup" → s-pmMsV1UVKG-xigkwj28ql`).

## Posting

Call `mcp__voxt-robokitty__post_message` with `chatId` and `text` exactly as resolved. On success, report the returned local id (LID) in one short line, e.g. `Posted (LID: 12345).` On failure, surface the error verbatim and do not retry automatically.

## Reading from a file

When `--file <path>` is set:
- Use the `Read` tool to load the file.
- Send its full contents as `text` (only trim a single trailing newline, if any).
- If the file is empty after trimming, stop and tell the user — do not post an empty message.

## Notes

- The message may contain Markdown / Voxt markup — pass it through unchanged.
- Do not add any prefix/suffix to the message (no "From Claude Code:", no signatures) unless the user typed it.
- This command posts immediately on success; treat it as a user-visible action — if the target is ambiguous, ask before sending.

Arguments: $ARGUMENTS
