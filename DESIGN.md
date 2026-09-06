---
name: Market Mate Spectral Edge
description: A light and dark evidence workspace with violet selection, spectral edging, and explicit authority states.
colors:
  background: "#f7f8fa"
  foreground: "#303945"
  card: "#ffffff"
  primary: "#7154b2"
  primary-foreground: "#ffffff"
  secondary: "#eef0f4"
  secondary-foreground: "#3f4653"
  muted: "#f0f1f5"
  muted-foreground: "#626b79"
  accent: "#eee9f7"
  accent-foreground: "#61449d"
  destructive: "#ad344b"
  border: "#dde1e8"
  input: "#cdd2dc"
  ring: "#9b84c9"
  good: "#277052"
  warning: "#92601c"
  spectral-mint: "#a4d8d0"
  spectral-rose: "#edbed6"
  spectral-violet: "#b8a2e5"
  sidebar-bg: "#fbfbfd"
  background-dark: "#14161d"
  foreground-dark: "#e5e7ed"
  card-dark: "#1c1f28"
  primary-dark: "#c2abea"
  primary-foreground-dark: "#21192e"
  secondary-dark: "#292d38"
  secondary-foreground-dark: "#e5e7ed"
  muted-dark: "#252934"
  muted-foreground-dark: "#a2aaba"
  accent-dark: "#332b44"
  accent-foreground-dark: "#d6c4f3"
  destructive-dark: "#f494a5"
  border-dark: "#333846"
  input-dark: "#464d5e"
  ring-dark: "#b39bde"
  good-dark: "#8ad4b4"
  warning-dark: "#e4be7c"
  spectral-mint-dark: "#729f9c"
  spectral-rose-dark: "#b685a1"
  spectral-violet-dark: "#a08ac8"
  sidebar-bg-dark: "#181b23"
typography:
  headline:
    fontFamily: "Geist, system-ui, sans-serif"
    fontSize: "27px"
    fontWeight: 450
    lineHeight: 1.2
    letterSpacing: "-0.03em"
  display:
    fontFamily: "Geist, system-ui, sans-serif"
    fontSize: "clamp(20px, 1.8vw, 27px)"
    fontWeight: 450
    lineHeight: 1.25
    letterSpacing: "-0.025em"
  title:
    fontFamily: "Geist, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 550
    lineHeight: 1.4
    letterSpacing: "-0.01em"
  body:
    fontFamily: "Geist, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "Geist, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 500
  mono:
    fontFamily: "Geist Mono, monospace"
    fontSize: "11px"
rounded:
  control: "calc(0.65rem - 2px)"
  nav: "7px"
  panel: "10px"
  pill: "9999px"
spacing:
  compact: "8px"
  small: "12px"
  medium: "16px"
  panel: "18px"
  inset: "20px"
  section: "24px"
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.primary-foreground}"
    rounded: "{rounded.control}"
    padding: "8px 16px"
    height: "36px"
  button-outline:
    backgroundColor: "{colors.background}"
    textColor: "{colors.foreground}"
    rounded: "{rounded.control}"
  input-search:
    rounded: "{rounded.control}"
    textColor: "{colors.foreground}"
    height: "36px"
    padding: "4px 12px 4px 32px"
  nav-item:
    textColor: "{colors.muted-foreground}"
    rounded: "{rounded.nav}"
    padding: "9px 12px"
  nav-item-active:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.accent-foreground}"
    rounded: "{rounded.nav}"
    padding: "9px 12px"
  state-chip:
    rounded: "{rounded.pill}"
    padding: "2px 8px"
  summary-card:
    backgroundColor: "{colors.card}"
    textColor: "{colors.foreground}"
    rounded: "{rounded.panel}"
    padding: "18px"
---

# Design System: Market Mate Spectral Edge

## Overview

**Creative North Star: "Spectral Edge"**

A calm working console with cloud-white and mist surfaces in light mode, charcoal and soft white in dark mode. Violet identifies selection and inspection links; a narrow mint–rose–violet edge supplies the distinctive atmospheric detail. The interface keeps evidence, timing, and authority readable without adopting the reference's hairline display type.

This refresh records the implemented frontend and supersedes the Night Desk palette and density. The incumbent commitments to display-only authority, visible distrust, and preserved evidence remain. Source authority is `frontend/app/globals.css`, the final cascade in `supervisory-overview.css`, and the shipped shadcn components; `command-ledger.css` supplies surviving Stage-1 layout rules.

**Key Characteristics:**
- Paired light and dark themes with persistent system, light, or dark preference.
- Softly rounded, bordered panels with restrained violet selection.
- Geist for reading, Geist Mono for identifiers and measured detail.
- Explicit trust labels, contained evidence tables, and stable record links.

## Colors

Violet and neutral fields provide the working palette; spectral pastels are decorative, while green, amber, and red carry independent status meaning. Frontmatter keys without a suffix describe light mode; matching `-dark` keys describe the `.dark` overrides. Component token references show light mode; runtime CSS custom properties switch them together.

### Primary
- **Violet:** primary links, positive chart fills, and primary controls; primary foreground supplies readable button text.
- **Violet wash:** accent background and accent foreground identify selected navigation and highlighted evidence targets.

### Secondary
- **Spectral mint, rose, and violet:** a narrow gradient along the authority strip; mint also accents the lettermark. These colors do not encode custody or completion.
- **Status green, amber, and red:** good, warning, and destructive tokens identify outcomes and exceptions, accompanied by visible words or signed values.

### Neutral
- **Cloud and charcoal:** background, card, and sidebar fields distinguish the page's major regions in each theme.
- **Slate and soft white:** foreground and muted foreground separate primary readings from supporting context.
- **Mist layers:** secondary and muted surfaces support badges, controls, and row hover. Border and input strokes define boundaries; ring marks keyboard focus.

**The State-Is-Text Rule.** Semantic color accompanies a visible state label or signed measurement; color alone never establishes trust.

**The Spectral Edge Rule.** Keep the decorative spectrum distinct from semantic status and use violet consistently for selection and inspection links.

## Typography

**Display and Body Font:** Geist, with system-ui and sans-serif fallbacks. **Data Font:** Geist Mono, with monospace fallback. Both are loaded through Next font variables.

The ramp is compact but no longer uses Night Desk microtype for core readings. Headlines use a moderate weight and tight tracking; labels stay sentence case on the overview. Stage-1 table headers retain uppercase treatment.

- **Headline:** page titles use the headline token, falling to 25px at the mobile breakpoint.
- **Display:** summary values use the fluid display token, fixed at 21px on mobile.
- **Title:** panel headings use the title token; Stage-1 section headings use 16px and mobile panel headings use 14px.
- **Body:** the base is the body token. Working descriptions and cells use 11–13px; Stage-1 cells use 12px with 1.6 line-height.
- **Label and data:** summary labels use the label token; compact identifiers, timestamps, and measurements use mono at 10–11px.

**The Data Voice Rule.** Use tabular figures throughout the console and Geist Mono for identifiers, timestamps, and measured detail; summary readings remain Geist.

## Layout

The desktop shell has a fixed 206px sidebar and a fluid main area capped at 1840px, with 28px top and 30px horizontal padding. Panels group content with recurring 14–24px gaps and 18–20px internal spacing. These are observed rhythms, not a strict uniform spacing scale.

The overview stacks an authority strip, four summary panels, a qualification/attention pair in a 1.15:1 ratio, and a full-width evidence dock. Panels grow with their content. The details route shares the shell and uses a 1.5:0.7 content grid, with full-width inventory sections.

At 1180px and below, the sidebar narrows to 180px while keeping labels; summaries become two columns and paired content becomes one column. At 720px, navigation moves into normal flow above content with three labeled columns and 44px minimum targets; main padding narrows to 14px and summaries remain two columns. At 360px and below, summaries stack. Above 1600px, summary padding expands to 22px.

Evidence tables retain their tabular shape and scroll within their containers: the overview has a 710px minimum table width; mobile detailed inventory retains 750px. Full identifiers wrap in the detail cells. Record anchors highlight the exact destination row.

## Elevation & Depth

Panels are flat, separated by tone and 1px borders. Shadcn controls retain subtle elevation: outline buttons use the library's extra-small shadow, and active tabs use its small shadow. This replaces the incumbent blanket prohibition on shadows, which no longer describes the build. Search explicitly removes its resting shadow. Keyboard focus uses the ring token: global outlines are 2px with a 3px offset, and shadcn controls add their 3px translucent ring.

**The Quiet Panel Rule.** Keep content panels flat; reserve subtle shadow and focus treatment for controls and selected tabs.

Motion is feedback: navigation and attention hover transitions last 140ms. Signed qualification bars settle over 500ms with `cubic-bezier(.16,1,.3,1)`, growing outward from the true zero baseline. Refresh indicates pending state with a spinning icon. Reduced-motion preference removes animations and transitions; theme changes suppress transition flashes.

## Shapes

Content panels and the authority strip use the panel radius; navigation and attention rank boxes use the nav radius. Shadcn controls derive rounded corners from the shared base radius of 0.65rem. Badges are pills, while legacy Stage-1 status chips use small 5px corners. The spectrum is a 2px horizontal edge, not a large background fill. Lucide stroke icons supply navigation and state imagery.

## Components

### Buttons

Shadcn Button supplies the actual variant API. Primary uses violet and its contrasting foreground; outline is the visible refresh treatment, with a background surface, border, and accent hover. Secondary uses the secondary surface; ghost gains accent on hover; link underlines on hover; destructive uses semantic red. These library variants exist, but their presence grants no authority-bearing action. Default height is 36px with 8px by 16px padding; small refresh uses 32px height and narrower icon-aware padding. Disabled controls reduce opacity to half. Keyboard focus uses the library ring.

### Chips

Shadcn Badge supplies outline custody and completion chips and secondary count badges. Custody chips combine icon and visible label with a current-color border on transparent ground. Completion badges carry visible state text. Stage-1 status chips retain their compact outlined shape.

### Cards / Containers

Summary and workspace panels use the card surface, border token, and panel radius. Summary panels contain a label, prominent reading, context, detailed measures, and an inspection link separated by a top rule. Workspace headers use 18px by 20px padding; linked attention rows use 15px by 20px padding and a muted hover surface. Cards themselves do not lift on hover.

### Inputs / Fields

The evidence filter is a real shadcn Input with an input-token border, control radius, muted placeholder, and inset search icon. It filters the currently displayed inventory; it does not imply a full archive search. Width is 250px on desktop and full width on mobile; height grows from 36px to at least 42px on mobile. Dark input backgrounds use a translucent input tone. Focus uses the ring; disabled and invalid styling comes from the primitive.

### Navigation

Labeled Lucide links are muted at rest, foreground on muted hover, and accent foreground on accent selection. Desktop rows have 42px minimum height and 13px type. Mobile rows keep their labels with 44px targets. The shared theme select persists system, light, or dark preference through `market-mate-theme`.

### Evidence Dock and Details

Real shadcn Tabs, Input, Badge, and Table compose the overview inventory. Tabs switch between research cycles and snapshots; active tabs use a raised neutral surface and violet text. Tables use quiet header fields, separated rows, mono identifiers, and explicit inspection links. Empty inventory and no matching results are separate labeled states. Details reuse the theme and shell, retain WU-46 acceptance IDs and display-only attributes, and expose full identifiers and digests at stable row anchors. The details route preserves its no-button/no-form contract.

## Do's and Don'ts

### Do:
- **Do** apply both theme values through semantic CSS custom properties.
- **Do** pair semantic color with visible state labels or signed values.
- **Do** retain labeled mobile navigation and contain wide evidence tables.
- **Do** preserve explicit environment, distrust, and zero-authority information.
- **Do** compose controls from the shipped shadcn primitives and retain keyboard focus.

### Don't:
- **Don't** add kickers or eyebrows above headings.
- **Don't** use the decorative spectrum as evidence of a successful or trusted state.
- **Don't** turn research measurements into claims of realized profit or executable orders.
- **Don't** inherit stale Night Desk microtype or unused legacy colors as new system tokens.

Not canonized: the legacy 7px uppercase detail-table captions and tiny chart-axis annotations are existing legibility debt, not a reusable text scale; unused Night Desk selectors are compatibility residue, not Spectral Edge rules.
