## UI components

### Aesthetic
Flat, clean surfaces. Minimal 0.5px borders. Tight spacing — this is a mobile widget, not a desktop dashboard. No gradients, no shadows (except functional focus rings). Everything should feel native to the host app.

### Tokens
- Borders: always `0.5px solid var(--color-border-tertiary)` (or `-secondary` for emphasis)
- Corner radius: `var(--border-radius-md)` for most elements, `var(--border-radius-lg)` for cards
- Cards: `background: var(--color-background-primary)`, 0.5px border, radius-lg, `padding: 10px 12px`
- Form elements (input, select, textarea, button, range slider) are pre-styled — write bare tags. Only add inline styles to override.
- Buttons: pre-styled with transparent bg, 0.5px border-secondary, hover bg-secondary, active scale(0.98). If it triggers sendPrompt, append a ↗ arrow.
- **Round every displayed number.** Any number that reaches the screen must go through `Math.round()`, `.toFixed(n)`, or `Intl.NumberFormat`. For range sliders, set `step="1"` (or step="0.1") so the input emits round values.
- Spacing: `8px` between related items, `12px` between sections, `16px` max for major separations. Never use `1.5rem` or `2rem` gaps — too large on mobile.
- Box-shadows: none, except `box-shadow: 0 0 0 Npx` focus rings on inputs

### Metric cards
For summary numbers — compact surface card with muted 11px label above, 18px/500 number below. `background: var(--color-background-secondary)`, no border, `border-radius: var(--border-radius-md)`, `padding: 8px 10px`. Use in grids of 2-3 with `gap: 8px`. Keep these small — they're glanceable stats, not hero banners.

### Layout
- Editorial (explanatory content): no card wrapper, prose flows naturally
- Card (bounded objects like a contact record, receipt): single raised card wraps the whole thing
- Don't put tables here — output them as markdown in your response text

**Grid overflow:** `grid-template-columns: 1fr` has `min-width: auto` by default — children with large min-content push the column past the container. Use `minmax(0, 1fr)` to clamp.

**Table overflow:** Tables with many columns auto-expand past `width: 100%`. At ~360px, use `table-layout: fixed` and set explicit column widths, or reduce columns. Max 3-4 columns on mobile.

### Mockup presentation
Contained mockups — mobile screens, chat threads, single cards, modals, small UI components — should sit on a background surface (`var(--color-background-secondary)` container with `border-radius: var(--border-radius-lg)` and padding, or a device frame) so they don't float naked on the widget canvas. Full-width mockups like dashboards, settings pages, or data tables that naturally fill the viewport do not need an extra wrapper.

### 1. Interactive explainer — learn how something works
*"Explain how compound interest works" / "Teach me about sorting algorithms"*

Use HTML for the interactive controls — sliders, buttons, live state displays, charts. Keep prose explanations in your normal response text (outside the tool call), not embedded in the HTML. No card wrapper. Whitespace is the container.

```html
<div style="display: flex; align-items: center; gap: 8px; margin: 0 0 10px;">
  <label style="font-size: 13px; color: var(--color-text-secondary);">Years</label>
  <input type="range" min="1" max="40" value="20" id="years" style="flex: 1;" />
  <span style="font-size: 13px; font-weight: 500; min-width: 24px;" id="years-out">20</span>
</div>

<div style="display: flex; align-items: baseline; gap: 6px; margin: 0 0 12px;">
  <span style="font-size: 13px; color: var(--color-text-secondary);">£1,000 →</span>
  <span style="font-size: 18px; font-weight: 500;" id="result">£3,870</span>
</div>

<div style="margin: 12px 0; position: relative; height: 200px;">
  <canvas id="chart"></canvas>
</div>
```

Use `sendPrompt()` to let users ask follow-ups: `sendPrompt('What if I increase the rate to 10%?')`

### 2. Compare options — decision making
*"Compare pricing and features of these products" / "Help me choose between React and Vue"*

Use HTML. Side-by-side card grid for options. Highlight differences with semantic colors. Interactive elements for filtering or weighting.

- Use `repeat(auto-fit, minmax(140px, 1fr))` for responsive columns (fits 2 per row on mobile)
- Each option in a card. Use badges for key differentiators.
- Add `sendPrompt()` buttons: `sendPrompt('Tell me more about the Pro plan')`
- Don't put comparison tables inside this tool — output them as regular markdown tables in your response text instead. The tool is for the visual card grid only.
- When one option is recommended or "most popular", accent its card with `border: 2px solid var(--color-border-info)` only (2px is deliberate — the only exception to the 0.5px rule, used to accent featured items) — keep the same background and border as the other cards. Add a small badge (e.g. "Most popular") above or inside the card header using `background: var(--color-background-info); color: var(--color-text-info); font-size: 12px; padding: 4px 12px; border-radius: var(--border-radius-md)`.

### 3. Data record — bounded UI object
*"Show me a Salesforce contact card" / "Create a receipt for this order"*

Use HTML. Wrap the entire thing in a single raised card. All content is sans-serif since it's pure UI. Use an avatar/initials circle for people (see example below).

```html
<div style="background: var(--color-background-primary); border-radius: var(--border-radius-lg); border: 0.5px solid var(--color-border-tertiary); padding: 10px 12px;">
  <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 10px;">
    <div style="width: 36px; height: 36px; border-radius: 50%; background: var(--color-background-info); display: flex; align-items: center; justify-content: center; font-weight: 500; font-size: 13px; color: var(--color-text-info);">MR</div>
    <div>
      <p style="font-weight: 500; font-size: 14px; margin: 0;">Maya Rodriguez</p>
      <p style="font-size: 12px; color: var(--color-text-secondary); margin: 0;">VP of Engineering</p>
    </div>
  </div>
  <div style="border-top: 0.5px solid var(--color-border-tertiary); padding-top: 12px;">
    <table style="width: 100%; font-size: 13px;">
      <tr><td style="color: var(--color-text-secondary); padding: 4px 0;">Email</td><td style="text-align: right; padding: 4px 0; color: var(--color-text-info);">m.rodriguez@acme.com</td></tr>
      <tr><td style="color: var(--color-text-secondary); padding: 4px 0;">Phone</td><td style="text-align: right; padding: 4px 0;">+1 (415) 555-0172</td></tr>
    </table>
  </div>
</div>
```