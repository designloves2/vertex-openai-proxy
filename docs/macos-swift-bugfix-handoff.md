# Handoff: two bugs fixed in the Node.js proxy, needed in the Swift port too

## Context

This project is a proxy that translates OpenAI-format API requests into
Google Vertex AI (Gemini) API requests. The original/Windows version is
implemented in Node.js (`index.js` in this repository). The macOS app's
proxy logic was independently reimplemented from scratch in Swift (Xcode) —
it does not run or share `index.js`.

Two real bugs were found and fixed in `index.js` on 2026-09-30 (commits
`825db10` and later on `main`). Please check whether the Swift
reimplementation has the same two patterns, and if so, fix them the same
way.

---

## Bug 1 (the actual root cause — fix this first): unguarded JSON decode of `tool_calls[].function.arguments`

**Symptom:** When a request to the chat-completions endpoint included a
large `tools` array (~90+ function/tool definitions), the request failed
with an HTTP 500 error whose message was a raw JSON-parser error string,
e.g.:

```
Unexpected non-whitespace character after JSON at position 30 (line 1 column 31)
```

With 0–3 tools in the request, it always worked. Only large tool counts
triggered it.

**Root cause:** When converting the conversation history back into the
model's request format, a prior assistant turn's `tool_calls` need to be
replayed. Each tool call's `arguments` field arrives as a JSON-encoded
string and must be decoded back into an object before being sent onward.
In `index.js`, that decode call had **no error handling**:

```js
// index.js, before the fix
const funcArgs = typeof tc.function.arguments === 'string'
    ? JSON.parse(tc.function.arguments || '{}')
    : tc.function.arguments;
```

A few lines below, the analogous decode for a *tool response's* content
(role `"tool"`) already had a try/catch with a safe fallback — only the
`tool_calls` argument decode was missing it. When many tools are in play,
a client is statistically more likely to send a slightly malformed or
truncated `arguments` string, and when decoding failed here, the raw
exception propagated all the way up to the route's top-level error handler,
which put the exception's `.message` directly into the client-facing JSON
error body. That's why the client saw a raw native JSON-parser error string
instead of a normal, well-formed API error.

**Fix applied in `index.js`:**

```js
// index.js, after the fix
let funcArgs;
try {
    funcArgs = typeof tc.function.arguments === 'string'
        ? JSON.parse(tc.function.arguments || '{}')
        : tc.function.arguments;
} catch (e) {
    console.warn(`[V1/CHAT] Failed to parse tool_call arguments for ${funcName}:`, e.message);
    funcArgs = {};
}
```

**What to check in the Swift code:** find where a previous assistant turn's
tool-call `arguments` string gets decoded (e.g. `JSONDecoder`,
`JSONSerialization.jsonObject`, or similar) before being sent back to
Gemini/Vertex. If that decode can throw and isn't wrapped in a `do/catch`
(or equivalent `try?`/`Result` handling), a malformed arguments string will
crash or fail that whole request instead of degrading gracefully. Fix: catch
the decode failure and fall back to an empty object/dictionary, plus a log
line, instead of letting the error propagate into the response.

---

## Bug 2 (found during investigation, real bug but not the actual trigger here)

**What it was:** In three places, `index.js` read an HTTPS response body by
appending each incoming data chunk directly onto a string:

```js
// before
let data = '';
proxyRes.on('data', chunk => data += chunk);
proxyRes.on('end', () => { /* use data */ });
```

`chunk` here is a raw `Buffer`, and `+=` implicitly stringifies each chunk
independently with default UTF-8 decoding. If a multi-byte UTF-8 character
(e.g. non-ASCII text in a description field) happens to be split across two
chunks, decoding each chunk separately can corrupt that character, since
each half is decoded without knowledge of the other half.

**Fix applied in `index.js`:** collect the raw chunks into an array and
decode once, after all chunks have arrived:

```js
// after
const chunks = [];
proxyRes.on('data', chunk => chunks.push(chunk));
proxyRes.on('end', () => {
    const data = Buffer.concat(chunks).toString('utf8');
    /* use data */
});
```

Note: this bug did **not** actually affect the exact request path in Bug 1
above — that path already called `proxyRes.setEncoding('utf8')`, which makes
Node's http module decode multi-byte sequences correctly across chunk
boundaries internally. Only a few call sites in `index.js` that build up a
full (non-streaming) response body were missing that protection.

**What to check in the Swift code:** wherever the Vertex AI HTTP response
body is read (e.g. `URLSession` data task callbacks, `URLSessionDataDelegate`
`didReceive data:`), check whether incoming `Data` chunks are converted to
`String` individually and concatenated, versus being accumulated as raw
`Data` and converted to `String` only once, after the full response has
arrived. If it's the former, switch to accumulating `Data` and decoding once
at the end.

---

## Summary of action needed

1. Find the Swift equivalent of "decode a replayed tool call's arguments
   JSON string" — add safe error handling with a fallback, matching Bug 1's
   fix.
2. Find the Swift equivalent of "read the Vertex AI HTTP response body" —
   confirm it accumulates raw bytes and decodes once, not per-chunk. Fix if
   it doesn't, matching Bug 2's fix.
3. Bug 1 is the confirmed real-world trigger (reproduced and fixed on the
   Node.js side, confirmed working via a live test with ~96 tools). Bug 2 is
   a correctness fix found along the way, lower priority.
