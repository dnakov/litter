# App mode: persistent state

When building for module `app`, the widget is rendered as a saved app —
relaunchable from a dedicated Apps screen, updatable on demand, and
critically, **its JSON state survives HTML regeneration**. The HTML may be
rewritten entirely when the user requests an update ("make the buttons
bigger"); the state blob rides across untouched. You are responsible for
reading old state defensively and writing forward-compatible shapes.

## Identity: the `app_id` slug

Every `show_widget` call must include an `app_id` — a short, lowercase,
hyphen-separated slug (e.g. `fitness-tracker`, `todo-list`,
`budget-calculator`). The slug is the **model-facing identity** of the
app:

- **Reuse the same `app_id`** in the current thread to update an
  existing app. The persisted JSON state (`window.loadAppState()`)
  will be preserved across the rewrite.
- **Pick a fresh `app_id`** to create a new app. It gets its own empty
  state slot.

Slugs are **scoped per-thread**. A `fitness-tracker` in thread A and a
`fitness-tracker` in thread B are independent apps with independent
state.

At the top of each thread's developer instructions you'll see a line
like:

```
Apps saved in this thread so far: fitness-tracker (Fitness Tracker), todo-list (Todo List)
```

Reuse one of those slugs to iterate on an existing app; pick something
new to start a fresh one. If the line is missing, no apps are saved in
this thread yet.

## JS bridge (injected before your code runs)

Three globals are available only in app mode:

```js
// Returns the parsed state object, or null if no state has ever been saved.
// Safe to call on every boot. Never throws — returns null on any error.
window.loadAppState()

// Serializes `obj` to JSON and asks the native host to persist it. Returns
// true when the request was dispatched. Persistence is async on the native
// side; there is no synchronous error for size-cap rejection (see below),
// but the host will drop writes that exceed the hard cap.
window.saveAppState(obj)

// One-shot schema-constrained AI query. Returns a Promise that resolves
// with a parsed JSON object matching `responseFormat`, or rejects with a
// readable Error on schema-parse failure, model refusal, timeout, or
// network error. Use it for AI-powered fields like calorie lookup,
// sentiment tagging, free-text→structured data extraction — things where
// you need the model, not just code.
//
//   const { calories } = await window.structuredResponse({
//     prompt: "i ate a big lasagna",
//     responseFormat: {
//       type: "object",
//       properties: { calories: { type: "number" } },
//       required: ["calories"],
//     },
//   });
//
// `responseFormat` is a raw JSON Schema object passed through to OpenAI
// structured-output mode (strict). Two constraints you MUST follow or
// the call will 400 at the model boundary:
//   1. `required` must list EVERY key in `properties` (strict mode).
//      If a field is genuinely optional, make its type nullable instead,
//      e.g. `{ type: ["string", "null"] }`, and still list it in `required`.
//   2. Set `additionalProperties: false` on every object.
// Keep schemas flat and small — one level of nesting, no more than a
// handful of fields.
window.structuredResponse({ prompt, responseFormat })
```

### Scope & lifecycle of `structuredResponse`

Calls within one opened app view share a hidden conversation context, so
a follow-up question can build on an earlier one ("and how many carbs?"
right after a calorie lookup). The context resets when the view closes
and reopens — it is **not** persisted across app launches. If you need
cross-session memory, embed the relevant history in each `prompt` from
your `saveAppState` data.

## State contract

- Always include an integer `schema_version` field. Bump it whenever the
  shape of the state you *write* changes.
- On boot, call `loadAppState()` and defensively migrate older shapes. A
  missing field is normal — treat `null`/`undefined`/absent as "new
  install" defaults.
- **Never assume DOM identity across regenerations.** The HTML you see now
  may be thrown away on the next update; only the state survives. If you
  need to remember something, it lives in state, not in a global `var`
  or a DOM attribute.

## Size limits

- Aim to keep state under **64 KB**. This is a soft guideline — plenty of
  room for a fitness tracker's workout log or a todo app's entries, but
  not for blob pastes or binary data.
- The native host enforces a **256 KB hard cap**. Writes that exceed it
  are silently dropped. Don't push up against this.

## Worked example — fitness tracker

Invoke with `show_widget(app_id: "fitness-tracker", title: "Fitness Tracker", widget_code: ...)`.
Later requests like "add a units toggle" should reuse `app_id:
"fitness-tracker"` so the stored entries survive.

```html
<style>
  :root { color-scheme: dark; }
  body { margin: 0; font: 14px/1.4 -apple-system, system-ui, sans-serif; color: #e6e6e6; }
  .app { padding: 16px; }
  .row { display: flex; gap: 8px; align-items: center; margin: 6px 0; }
  input, button { background: #1c1c1e; color: inherit; border: 1px solid #333; border-radius: 6px; padding: 6px 10px; }
  button { cursor: pointer; }
  ul { list-style: none; padding: 0; margin: 12px 0 0; }
  li { padding: 8px; border-top: 1px solid #222; }
</style>

<div class="app">
  <h2>Workout log</h2>
  <div class="row">
    <input id="name" placeholder="Exercise" />
    <input id="reps" placeholder="Reps" type="number" inputmode="numeric" />
    <button id="add">Add</button>
  </div>
  <ul id="entries"></ul>
</div>

<script>
(function () {
  // 1. Load + migrate. Old versions may be missing fields; fill sensible defaults.
  var CURRENT_SCHEMA = 2;
  var loaded = window.loadAppState && window.loadAppState();
  var state = {
    schema_version: CURRENT_SCHEMA,
    entries: (loaded && Array.isArray(loaded.entries)) ? loaded.entries : [],
    // v2 added `units`. Older state may not have it — default to 'metric'.
    units: (loaded && typeof loaded.units === 'string') ? loaded.units : 'metric',
  };

  // 2. Debounce writes so rapid edits don't spam saves.
  var saveTimer = null;
  function saveSoon() {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(function () {
      if (window.saveAppState) window.saveAppState(state);
    }, 250);
  }

  function render() {
    var ul = document.getElementById('entries');
    ul.innerHTML = '';
    state.entries.forEach(function (entry, i) {
      var li = document.createElement('li');
      li.textContent = entry.name + ' — ' + entry.reps;
      ul.appendChild(li);
    });
  }

  document.getElementById('add').addEventListener('click', function () {
    var name = document.getElementById('name').value.trim();
    var reps = parseInt(document.getElementById('reps').value, 10) || 0;
    if (!name) return;
    state.entries.push({ name: name, reps: reps });
    render();
    saveSoon();
  });

  render();
})();
</script>
```

Key points in the example:
- `schema_version` is a top-level integer, set on every write.
- The migration block handles both "nothing loaded" (first run) and "old
  shape missing `units`" (upgraded install) without throwing.
- Writes are debounced with `setTimeout` to coalesce rapid input.
- No DOM identity is assumed across reloads — the render function
  rebuilds the list from `state.entries` every time.

## Worked example — calorie lookup with `structuredResponse`

A food-tracker that lets the user type natural language ("i ate a big
lasagna") and logs it with the model's best calorie estimate. Invoke
with `show_widget(app_id: "food-tracker", title: "Food Tracker",
widget_code: ...)`.

```html
<style>
  :root { color-scheme: dark; }
  body { margin: 0; font: 14px/1.4 -apple-system, system-ui, sans-serif; color: #e6e6e6; }
  .app { padding: 16px; }
  .row { display: flex; gap: 8px; align-items: center; margin: 6px 0; }
  input, button { background: #1c1c1e; color: inherit; border: 1px solid #333; border-radius: 6px; padding: 6px 10px; }
  button { cursor: pointer; }
  button[disabled] { opacity: 0.5; cursor: default; }
  ul { list-style: none; padding: 0; margin: 12px 0 0; }
  li { padding: 8px; border-top: 1px solid #222; display: flex; justify-content: space-between; }
  .error { color: #f87171; margin: 6px 0; font-size: 12px; }
</style>

<div class="app">
  <h2>Food log</h2>
  <div class="row">
    <input id="desc" placeholder="What did you eat?" />
    <button id="add">Add</button>
  </div>
  <div id="error" class="error"></div>
  <ul id="entries"></ul>
</div>

<script>
(function () {
  var CURRENT_SCHEMA = 1;
  var loaded = window.loadAppState && window.loadAppState();
  var state = {
    schema_version: CURRENT_SCHEMA,
    entries: (loaded && Array.isArray(loaded.entries)) ? loaded.entries : [],
  };

  var CALORIE_SCHEMA = {
    type: 'object',
    properties: { calories: { type: 'number' } },
    required: ['calories'],
    additionalProperties: false,
  };

  function save() {
    if (window.saveAppState) window.saveAppState(state);
  }

  function render() {
    var ul = document.getElementById('entries');
    ul.innerHTML = '';
    state.entries.forEach(function (e) {
      var li = document.createElement('li');
      li.innerHTML = '<span>' + e.desc + '</span><span>' + e.calories + ' kcal</span>';
      ul.appendChild(li);
    });
  }

  document.getElementById('add').addEventListener('click', async function () {
    var btn = this;
    var input = document.getElementById('desc');
    var err = document.getElementById('error');
    var desc = input.value.trim();
    if (!desc) return;
    err.textContent = '';
    btn.disabled = true;
    try {
      var result = await window.structuredResponse({
        prompt: 'Estimate calories for: ' + desc,
        responseFormat: CALORIE_SCHEMA,
      });
      // Validate defensively — schema-constrained but still worth checking.
      var kcal = Number(result && result.calories);
      if (!isFinite(kcal)) throw new Error('no numeric calories in response');
      state.entries.push({ desc: desc, calories: Math.round(kcal) });
      input.value = '';
      render();
      save();
    } catch (e) {
      err.textContent = 'Could not estimate: ' + (e.message || e);
    } finally {
      btn.disabled = false;
    }
  });

  render();
})();
</script>
```

Key points:
- The button is disabled while the Promise is pending. `structuredResponse`
  is async and rate-limitable; never fire one on every keystroke.
- The result is validated (`isFinite(Number(...))`) even though the schema
  is strict. The model can still produce edge-case shapes you didn't
  anticipate; treat it like any network call.
- Successful results are persisted via `saveAppState`. The ephemeral
  `structuredResponse` thread does NOT persist across app launches —
  only your own `saveAppState` does.

## What to avoid

- Don't store secrets, credentials, or tokens in app state. It is
  low-sensitivity local storage, not a credential store.
- Don't rely on the HTML surviving. If a field or button matters,
  reflect it in state.
- Don't call `saveAppState` on every keystroke. Debounce.
- Don't emit state >64 KB. Prune history, dedupe, or aggregate.
- Don't call `structuredResponse` for computations you can do locally —
  arithmetic, regex parsing, date math. Each call is a model round-trip.
- Don't fire `structuredResponse` in a render or keystroke loop. Gate it
  behind an explicit user action and disable the trigger while the
  Promise is pending.
- Don't trust a `structuredResponse` result without a sanity check in
  your own code. Schema-constrained does not mean semantically correct
  (the model could return `0` or a string that parses as a number).
- Don't rely on `structuredResponse` for persistence. The hidden thread
  it uses resets when the app view closes. Persist anything you need
  later via `saveAppState`.
