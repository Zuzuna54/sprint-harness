# §E — UI Components & Pages

**Goal:** pages, components, server/client split, state management, mobile responsiveness.

**Skip if:** `sections_answers.A.backend_only == true` OR `A.no_ui == true`.

## Discovery goals

1. New pages (routes + purpose + server/client)
2. New components (reusable vs page-specific + reuse opportunities)
3. Server vs client split (`'use client'` boundaries)
4. State management — TanStack Query (server) vs Redux (UI) vs local React state
5. Mobile responsive behavior at 375px/768px/1024px+

## Typical question shape

- E1 — **Pages**: "Based on §A and §F (UX flow), I'd propose these routes: <pre-filled based on existing `app/(dashboard)/` structure>. Modify?"
- E2 — **Components**: "I scanned `apps/web/components/` and found 5 candidates for reuse: <list>. New components proposed: <list with paths>. Accept reuse picks + confirm new ones?"
- E3 — **Server/client**: "For each component in E2:
  - **Server (no 'use client')**: pure display, no interactivity
  - **Client ('use client')**: hooks, event handlers, state
    Auto-classified based on usage; review each."
- E4 — **State management**: "<BRAND_SLUG_TITLE> rule: TanStack Query for server state (with `QUERY_KEYS` factory), Redux ONLY for UI state (module toggles, sidebar, drag, modals). Local React state for everything else. Confirm split for this sprint?"
- E5 — **Mobile**: "What changes at 375px (iPhone SE)? 768px (iPad)? 1024px+ (desktop)? Most <BRAND_SLUG_TITLE> surfaces are mobile-first with desktop adjustments — confirm or call out per surface."

## Conditional follow-ups

- If E2 proposes a brand-new component that overlaps an existing → push reuse: "I see `<existing>.tsx` does X — extend it instead of creating new?"
- If E3 flags a server component using hooks → BLOCK: "Hooks require 'use client'. Reclassify or convert to client."
- If E4 proposes new Redux slice for server state → push back: "TanStack Query handles server state. Redux only for ephemeral UI."
- If E5 omits 375px → require: "Mobile is the primary surface. What renders at 375px?"

## Output flags

- `new_pages: [<routes>]`
- `new_components: [<paths>]`
- `existing_components_modified: [<paths>]`
- `requires_use_client: [<paths>]`

## Recall targets

- `frontend-hook-pattern` (TanStack Query + Redux split)
- `onboarding-pattern` (if onboarding-adjacent)
- `<BRAND_NAME> web: no touch gestures` (if mobile-heavy)
- `<BRAND_NAME> Planner design-parity` (if planner-adjacent)

## Style guidance

- Grep `apps/web/components/` aggressively — most "new" components are extensions
- Server components are the <BRAND_SLUG_TITLE> default; client only when interactivity requires it
- Mobile-first is non-negotiable — every page must work at 375px
