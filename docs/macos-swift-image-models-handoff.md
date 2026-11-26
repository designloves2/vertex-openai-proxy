# Handoff for the macOS (Swift/Xcode) app: image models + full model list

Written 2026-11-26 from a Windows session. Branch: `feat/image-models-and-model-list`
(see `git log` on that branch for the `index.js` diff). The macOS app is a
separate Swift reimplementation, so none of this carries over automatically —
port the same behavior into the Swift proxy logic.

## 1. `/v1/models` = live Vertex catalog (all modalities)

- Call `GET https://us-central1-aiplatform.googleapis.com/v1beta1/publishers/google/models?pageSize=200`
  (follow `nextPageToken`) with `Authorization: Bearer <ADC token>` and
  `x-goog-user-project: <PROJECT_ID>`. Model id = last path segment of
  `publisherModels[].name`. Cache for 1 hour; `?refresh=1` busts the cache.
  On failure, fall back to a hardcoded list (see `FALLBACK_MODELS` in `index.js`).
- Classify each id (`classifyModel` in `index.js`):
  `automl*` → other; `imagen*` or `*-image` / `*-image-*` → **image**;
  `veo*` → video; `*embedding*` → embedding; `*tts*`, `chirp*`, `lyria*`,
  `*native-audio*` → audio; `gemini*`/`gemma*` → chat.
- Every entry gets extra fields: `type`, `input_modalities`,
  `output_modalities`, `capabilities.image_generation`.
  `?type=image` (comma-separated) filters by type.
- Live result on the test project: 134 models (37 chat, 10 image, 9 embedding,
  11 audio, 3 video, rest other).

## 2. `POST /v1/images/generations` (new, OpenAI-compatible)

Body: `model`, `prompt`, `n` (1–4), `size` (`WxH`, mapped to the nearest
aspect ratio 1:1/16:9/9:16/4:3/3:4/3:2/2:3) or `aspect_ratio`,
`response_format` (`b64_json` default, or `url` → a `data:` URI),
optional `image`/`images` (data URI / http URL / raw base64) as edit inputs,
optional `parameters` (passed straight to Imagen). Default model:
`IMAGE_MODEL_ID` env, else `imagen-4.0-generate-001`.

- **Imagen** → `POST .../locations/{loc}/publishers/google/models/{model}:predict`
  with `{instances:[{prompt}], parameters:{sampleCount, aspectRatio}}`.
  `loc` = `us-central1` when the configured location is `global`
  (Imagen is not served on `global`). Output: `predictions[].bytesBase64Encoded`.
- **Gemini image models** → `:generateContent` with
  `generationConfig.responseModalities = ["TEXT","IMAGE"]` and
  `imageConfig.aspectRatio`; input images go in as `inlineData` parts before
  the text. Output: `candidates[0].content.parts[].inlineData`. `n` > 1 = n calls.
- Response: `{created, data:[{b64_json | url, revised_prompt?}]}`.

## 3. Image models via `/v1/chat/completions`

If the resolved model classifies as image, skip the normal chat path: take
the last user message (text = prompt, `image_url` parts = edit inputs, ignored
for Imagen), generate, and answer with one assistant message whose content is
the model's text plus `![image N](data:<mime>;base64,...)` per image. When
`stream: true`, send it as one SSE chunk + a `finish_reason: "stop"` chunk + `[DONE]`.

## 4. Bug fix: `thinkingLevel` only for Gemini 3

Sending `generationConfig.thinkingConfig.thinkingLevel` to `gemini-2.5-*`
(or older) returns 400 "thinking_level is not supported by this model".
Only add it when the model id matches `/gemini-3/i`. Check the Swift code for
the same unconditional `thinkingLevel`.

## Verified on Windows (live Vertex)

- `/v1/models` live list ✔, `?type=image` filter ✔
- `gemini-2.5-flash-image`, `gemini-3.1-flash-image` via `/v1/images/generations` ✔
- `gemini-3.1-flash-image` via chat completions, streaming ✔
- `gemini-2.5-flash` and `gemini-3.1-pro-preview` text chat ✔ (after fix #4)
- Imagen: code path not verified — the test project returns 404 "not found or
  no access" for all `imagen-*` models (model access not enabled there).

## 5. Multi-turn image editing (conversation memory) — added later the same day

For Gemini image models in `/v1/chat/completions`, send the **whole**
conversation instead of only the last user message:
- system/developer messages → `systemInstruction`.
- user/assistant text is scanned for markdown data-URI images
  (`![..](data:<mime>;base64,<b64>)`); text before/after becomes text parts,
  each image becomes an `inlineData` part. Assistant → role `model`.
- Assistant image parts get `thoughtSignature` from an LRU cache (500 entries,
  key = sha1 of the base64) filled from the response parts' `thoughtSignature`
  when the image was generated; fall back to `skip_thought_signature_validator`.
- Image generation retries once on timeout/429/5xx; per-request timeout 120 s.
Verified: 2-turn edit ("blue circle" → "make it red") with `gemini-2.5-flash-image`.

Client-app guidance (for the image app / chat app sessions): `docs/client-app-dev-guide.md`.
