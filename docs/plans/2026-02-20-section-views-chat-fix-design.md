# Left Pane Section Views + Chat Error Fix Design

**Date:** 2026-02-20
**Status:** Approved

## Problem Statement
1. Chat returns "Server busy" / error messages due to Claude API 529s, missing retry for 429s, and unhandled `chat_response` error type
2. Left pane sections are placeholders — zero views consume `selectedSection` environment value
3. The environment key is private to CortexApp module, invisible to CortexCore views

## Architecture

### Chat Fix (Python + Swift)
- Add 429 to retryable errors in chat.py
- Don't inject raw retry text into chat bubbles
- Handle `chat_response` in MessageRouter
- Add streaming timeout safety net in ChatStore
- Graceful model fallback (Opus → Sonnet on 529)

### Environment Key Fix
- Move CortexSelectedSectionKey to CortexCore as public
- Each view reads @Environment(\.cortexSelectedSection)

### Section Content (8 views, 42 total sections)
Each view switches content based on selectedSection string match.
Scanner sections use ScannerFilterStore to auto-apply type filters.
Squadrons sections filter to individual squadron.
