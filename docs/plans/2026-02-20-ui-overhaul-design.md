# Cortex UI Overhaul Design

**Date:** 2026-02-20
**Status:** Approved
**Scope:** Full UI modernization across Navigation, Chat, War Room, and Scanner

## Problem Statement

The Cortex macOS app has several critical UI issues:
1. Left pane sections are decorative — clicking them changes nothing
2. Chat input is unstyled and responses render raw markdown
3. War Room and Scanner are visually bland for a professional trading terminal
4. Scanner shows only 9 results (hardcoded watchlist) and filters produce zero results (nil field values)

## Architecture

### 5 Independent Work Streams

| Stream | Domain | Key Files |
|--------|--------|-----------|
| A | Navigation overhaul | ContentView, ContextPaneView, TabBarView, AppTab, all views |
| B | Chat pane modernization | CortexAIPane, ChatStore |
| C | War Room redesign | WarRoomView, KPIBar, SquadronCard, OpportunityCard |
| D | Scanner redesign | ScannerView, ScannerFilterStore |
| E | Scanner backend fixes | market_data.py, main.py |

### Stream A: Navigation

- Wire `selectedSection` into every view so left pane selections actually switch content
- Add collapse-to-icons mode (`isContextPaneCollapsed` state, 52px icon rail vs 220px full)
- Convert top tabs from icon+label to text-only pill buttons (modern terminal aesthetic)
- Keyboard shortcut Cmd+B toggles between full/icon/hidden states

### Stream B: Chat Pane

- Modern input container: rounded rectangle with subtle border, inner padding, 12px from bottom edge
- MarkdownMessageView: parse and render code blocks with syntax highlighting, headers, lists, bold/italic
- Typing indicator animation for streaming responses
- Message timestamps and copy-to-clipboard on hover

### Stream C: War Room

- Animated KPI cards with sparkline trend charts
- Real-time pulse indicators on squadron status
- Glassmorphism card design with depth and hierarchy
- Opportunity feed with priority heat visualization
- Activity feed with severity-based styling and grouping

### Stream D: Scanner

- Professional data table with sortable columns
- Working filter chips with result counts
- Expanded detail panel with mini charts
- Score visualization with gradient heat bars
- Graceful nil handling in all filters (treat nil as "Unknown", show in results)

### Stream E: Scanner Backend

- Expand DEFAULT_WATCHLIST from 9 to 50+ diverse symbols across sectors
- Populate sector from Polygon.io ticker details API
- Populate market_cap classification (Mega/Large/Mid/Small) from market cap data
- Add sector diversity: Tech, Healthcare, Finance, Energy, Consumer, Industrial, etc.

## Design Tokens

Consistent across all streams:
- Background: `Color(white: 0.06)` (deepest), `Color(white: 0.08)` (cards), `Color(white: 0.10)` (hover)
- Accent: `.cyan` (primary), `.blue` (secondary)
- Profit: `.green`, Loss: `.red`, Warning: `.orange`
- Border: `Color(white: 0.12)` (default), `Color(white: 0.18)` (hover)
- Corner radius: 8px (cards), 6px (badges), 12px (input containers)
- Font: `.monospaced` for all data values, `.default` for labels
