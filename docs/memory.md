# Memory Management

Autobot implements a two-layer memory system with automatic consolidation to manage long conversations efficiently.

---

## Overview

As conversations grow, sending all previous messages to the LLM becomes:
- **Expensive** - More tokens = higher costs
- **Slow** - Larger context = slower responses
- **Limited** - Eventually hits model context limits (200K tokens for Claude)

Memory consolidation solves this by:
1. **Summarizing** old messages into compact memory
2. **Keeping** only recent messages in full context
3. **Archiving** important facts for later retrieval

---

## Two-Layer Memory

### 1. MEMORY.md (Long-term Facts)
**Location:** `workspace/memory/MEMORY.md`

Stores important facts that should persist across sessions:
- User information (location, preferences, habits)
- Project context (tech stack, architecture decisions)
- Important decisions and outcomes
- Tools and services used

**Updated:** During memory consolidation when new facts are learned.

**Usage:** Loaded into every LLM request as part of system context.

### 2. HISTORY.md (Searchable Log)
**Location:** `workspace/memory/HISTORY.md`

Append-only log of consolidated conversation summaries:
- Each entry is 2-5 sentences with timestamp
- Grep-searchable for finding past discussions
- Contains enough detail to recall context

**Updated:** After each consolidation with new summary entry.

**Usage:** Search with `grep "keyword" workspace/memory/HISTORY.md` to recall past context.

---

## How Consolidation Works

### Trigger
Consolidation runs automatically when:
```
session.messages.size > memory_window
```

Default `memory_window: 50` means consolidation after 50 messages.

### Process

1. **Extract old messages**
   - Keep last 10 messages (recent context)
   - Archive everything older for consolidation

2. **Send to LLM** (parallel, non-blocking)
   - Format old messages as conversation history
   - Include current MEMORY.md content
   - Ask LLM to:
     - Write 2-5 sentence summary for HISTORY.md
     - Update MEMORY.md with any new facts

3. **Update files**
   - Append summary to HISTORY.md
   - Replace MEMORY.md if facts changed

4. **Trim session**
   - Keep only last 10 messages
   - Save trimmed session to disk

### Parallel Execution

Consolidation runs in a background fiber:
```crystal
spawn do
  perform_consolidation(...)
end
```

**Benefits:**
- Agent continues processing immediately
- No blocking wait for LLM response
- User sees faster response times

---

## Configuration

### Enable Consolidation (Default)

```yaml
agents:
  defaults:
    memory_window: 50  # Consolidate after 50 messages
```

**When to use:**
- Long-running conversations
- Want searchable history
- Need persistent facts across sessions

**Behavior:**
- Consolidates after N messages
- Keeps last 10 messages in full context
- Archives older messages as summaries

### Disable Consolidation

```yaml
agents:
  defaults:
    memory_window: 0  # Disable consolidation
```

**When to use:**
- Short conversations (under 50 messages)
- Testing/development
- Want full message history always available
- Don't want LLM-generated summaries

**Behavior:**
- No consolidation happens
- Keeps only last 10 messages (simple trim)
- No MEMORY.md or HISTORY.md updates
- Eventually hits context limits on very long conversations

### Custom Window Size

```yaml
agents:
  defaults:
    memory_window: 100  # Consolidate after 100 messages
```

**Lower values (20-40):**
- More frequent consolidation
- Smaller context windows
- Lower costs per request
- More aggressive summarization

**Higher values (80-150):**
- Less frequent consolidation
- Larger context windows
- More detailed recent history
- Higher costs per request

---

## Constants

Memory behavior is controlled by these constants in `MemoryManager`:

| Constant | Value | Description |
|----------|-------|-------------|
| `DISABLED_MEMORY_WINDOW` | 0 | Setting `memory_window: 0` disables consolidation |
| `MIN_KEEP_COUNT` | 2 | Minimum messages to keep after consolidation |
| `MAX_KEEP_COUNT` | 10 | Maximum messages to keep after consolidation |
| `MAX_MESSAGES_WITHOUT_CONSOLIDATION` | 10 | When disabled, trim to this many messages |

---

## File Structure

```
workspace/
├── memory/
│   ├── MEMORY.md     # Long-term facts (replaced on update)
│   └── HISTORY.md    # Searchable log (append-only)
└── sessions/
    └── session.jsonl # Full message history
```

**Permissions:**
- `memory/` directory: `0o700` (user-only access)
- `MEMORY.md`: `0o600` (user read/write only)
- `HISTORY.md`: `0o600` (user read/write only)

Set automatically by `autobot new` command.

---

## Examples

### Example 1: Enabled with Default Window

**Config:**
```yaml
agents:
  defaults:
    memory_window: 50
```

**Behavior:**
```
Messages 1-40:  Normal conversation
Message 51:     Consolidation triggers
                - Keep messages 41-51 in context
                - Summarize messages 1-40
                - Update MEMORY.md + HISTORY.md
Message 52-101: Normal conversation
Message 102:    Consolidation triggers again
                - Keep messages 92-102
                - Summarize messages 41-91
```

### Example 2: Disabled

**Config:**
```yaml
agents:
  defaults:
    memory_window: 0
```

**Behavior:**
```
Messages 1-10:  Normal conversation
Message 11:     Trim to last 10 messages (keep 2-11)
Message 12:     Trim to last 10 messages (keep 3-12)
...
No consolidation, no MEMORY.md updates, no HISTORY.md entries
```

### Example 3: Aggressive Consolidation

**Config:**
```yaml
agents:
  defaults:
    memory_window: 20
```

**Behavior:**
```
Message 21:  Consolidate (keep 11-21)
Message 41:  Consolidate (keep 31-41)
Message 61:  Consolidate (keep 51-61)
...
Frequent consolidation, smaller context, lower cost per request
```

---

## Searching Memory

### Search HISTORY.md

Find past discussions about specific topics:
```bash
# Search for all mentions of "deployment"
grep -i "deployment" workspace/memory/HISTORY.md

# Search with context (2 lines before/after)
grep -C2 "api changes" workspace/memory/HISTORY.md

# Search by date
grep "2025-01-15" workspace/memory/HISTORY.md
```

### Read MEMORY.md

View current long-term facts:
```bash
cat workspace/memory/MEMORY.md
```

The LLM automatically reads this file at the start of each conversation.

---

## Troubleshooting

### Consolidation not happening

**Check:**
1. Is `memory_window` set to 0? (disabled)
2. Have you exceeded the window size?
3. Check logs for consolidation errors

**Solution:**
```yaml
agents:
  defaults:
    memory_window: 50  # Ensure it's not 0
```

### Consolidation too slow

**Symptoms:** Long pauses during conversation

**Cause:** Consolidation is CPU/network intensive

**Solution:** Consolidation already runs in parallel (non-blocking). If still slow:
- Increase `memory_window` to consolidate less often
- Use faster model for consolidation
- Check network latency to LLM provider

### Memory files have wrong permissions

**Symptoms:** Permission denied errors

**Cause:** Files created by different user (e.g., root in Docker)

**Solution:**
```bash
# Fix ownership (replace 1000:1000 with your user:group)
chown -R 1000:1000 workspace/memory/

# Or fix permissions
chmod 700 workspace/memory/
chmod 600 workspace/memory/*.md
```

### Context limit still exceeded

**Symptoms:** Error about context window even with consolidation enabled

**Cause:** `memory_window` set too high, or individual messages are very large

**Solution:**
- Lower `memory_window` to 30-40
- Break up very long messages into smaller chunks
- Consider disabling and manually managing conversation length

---

## Best Practices

### For Long Conversations
- **Enable consolidation** (`memory_window: 50`)
- Periodically review `MEMORY.md` for accuracy
- Use `grep` on `HISTORY.md` to recall past topics

### For Short Sessions
- **Disable consolidation** (`memory_window: 0`)
- Simpler, faster, no LLM overhead
- Suitable for quick tasks under 50 messages

### For Cost Optimization
- **Lower window** (`memory_window: 30`)
- More aggressive consolidation
- Smaller context = lower token costs
- Trade-off: less recent context available

### For Maximum Context
- **Higher window** (`memory_window: 100`)
- Less frequent consolidation
- More full messages in context
- Trade-off: higher costs per request

---

## Technical Details

### Consolidation Prompt

The LLM receives:
```
Current Long-term Memory: <content of MEMORY.md>

Conversation to Process: <formatted old messages>

Return JSON:
{
  "history_entry": "2025-01-15 10:30: User asked about deployment. Discussed Docker setup and CI/CD pipeline. Decided on GitHub Actions.",
  "memory_update": "<updated MEMORY.md with new facts>"
}
```

### Message Format

Messages sent for consolidation:
```
[2025-01-15 10:30] USER: how do I deploy this?
[2025-01-15 10:31] ASSISTANT [tools: exec, read_file]: I'll help you...
[2025-01-15 10:32] USER: what about Docker?
```

### Session Trimming

After consolidation:
```crystal
session.messages = session.messages[-keep_count..]  # Keep last 10
@sessions.save(session)
```

Only recent messages remain in the active session file.

---

## See Also

- [Configuration Guide](deployment.md) - Full config options
- [Security Guide](security.md) - File permissions and isolation
- [Architecture Overview](architecture.md) - System design
