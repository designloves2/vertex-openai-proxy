# Vertex AI to OpenAI Local Proxy

A local proxy that translates OpenAI-format API requests (`/v1/chat/completions`, `/v1/responses`) into Google Vertex AI (Gemini) API requests, so OpenAI-compatible tools and coding agents can talk to Gemini models on Vertex AI.

This project was inspired by an earlier open-source Vertex-to-OpenAI proxy concept, but the authentication, model routing, streaming parser, and tool-calling logic have been substantially rewritten to fix issues that caused authentication failures, wrong model routing, broken streaming, and multi-turn tool-calling errors on Gemini 3.x. See `CHANGELOG.md` for the full list of changes and [LICENSE](./LICENSE) for licensing terms.

## 🔥 Features
- **OpenAI API Compatibility:** Supports `/v1/chat/completions` and `/v1/responses`, both streaming and non-streaming.
- **Google ADC Authentication:** Uses `google-auth-library`'s `GoogleAuth` with Application Default Credentials — no OAuth client ID/secret needed. Authenticate once with `gcloud auth application-default login`.
- **Dynamic Model Routing:** The model requested by the client (e.g. `gemini-3-flash`, `gemini-3.1-pro`) is passed through to Vertex AI instead of being overridden by a fixed `.env` value.
- **Gemini 3.x Flash Tuning:** Detects Gemini 3 Flash models and configures `thinkingConfig` (`thinkingLevel: "high"`) appropriately instead of forcing generic temperature/topP/topK defaults.
- **Robust SSE Streaming Parser:** Rewritten to buffer partial chunks and only parse complete `data:` lines, fixing `Could not parse SSE event` errors seen with the original parser.
- **Multi-turn Function Calling for Gemini 3:** Captures and restores the `thought_signature` required by Gemini 3 across tool-call turns using an LRU cache, fixing `Function call is missing a thought_signature (400)` errors.
- **Multimodal Input:** Accepts images as data URIs or fetchable `http(s)` URLs and converts them to Gemini's `inlineData` format.

## ⚙️ Installation

### One-command setup (recommended)

Clone the repo, then run the installer for your OS. It installs Node.js/gcloud if missing, runs `gcloud auth application-default login`, writes `.env` interactively, grants the `roles/aiplatform.user` IAM role, enables the Vertex AI API, and installs npm dependencies. It also creates a run script (`vertex-openai-proxy-run.bat` on Windows, `vertex-openai-proxy-run.sh` on macOS) so you can start the server later without remembering any commands.

**macOS:**
```bash
git clone <this-repo-url>
cd vertex-openai-proxy
chmod +x install-mac.sh
./install-mac.sh
```

**Windows:**
```bash
git clone <this-repo-url>
cd vertex-openai-proxy
```
Then just double-click **`install-windows.bat`** in File Explorer (it launches the PowerShell installer for you, bypassing execution-policy prompts).

Or run it from PowerShell directly:
```powershell
powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
```
> If Node.js or the Google Cloud CLI had to be installed, the script will ask you to close the window and re-run it once (double-click the `.bat` again) in a fresh terminal so the new `PATH` is picked up.

### Manual setup

1. Clone the repository and install dependencies:
```bash
git clone <this-repo-url>
cd vertex-openai-proxy
npm install
```

2. Configure your environment variables by creating a `.env` file:
```env
# Required
GOOGLE_CLOUD_PROJECT_ID=your-gcp-project-id
GOOGLE_CLOUD_LOCATION=global
GOOGLE_CLOUD_MODEL_ID=gemini-1.5-flash-002

# Optional
PORT=3000
```

3. Authenticate with Google Cloud using Application Default Credentials:
```bash
gcloud auth application-default login
```
Make sure your account has the `roles/aiplatform.user` role on the target project:
```bash
gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
  --member="user:YOUR_EMAIL@gmail.com" \
  --role="roles/aiplatform.user"
```

4. Start the server:
```bash
npm run start
```
The proxy listens on `http://localhost:3000` by default (override with `PORT`).

> Note: the repo also ships a legacy `auth.js` (`npm run auth`) that performs an OAuth client-credential flow. It is kept for reference but is not required — `gcloud auth application-default login` is the supported authentication path.

## 🤖 Configuring your AI Agents

Point any OpenAI-compatible client at the proxy:

*   **API Provider:** `OpenAI Compatible`
*   **Base URL:** `http://localhost:3000/v1`
*   **API Key:** `sk-anything` (ignored by the proxy; it uses your local Google ADC credentials)
*   **Model Name:** whatever Gemini model you want to call, e.g. `gemini-3.1-pro`, `gemini-3-flash`, `gemini-1.5-flash-002`

### Supported Agents
Tested with OpenAI-compatible clients such as:
- Kilo Code
- Cline & Roo Code
- Any OpenAI-compatible library (LangChain, LlamaIndex, etc.)

## 🏗️ Architecture

1. **Request Interceptor:** Parses OpenAI-format messages (system/user/assistant/tool turns).
2. **Model Router:** `resolveVertexModel()` maps the client-requested model name to the Vertex model ID, applying aliases only when needed.
3. **Multimodal Normalizer:** Converts data-URI and `http(s)` images into Gemini's `inlineData` Base64 parts.
4. **SSE Stream Mapper:** Opens a streaming connection to `aiplatform.googleapis.com`, buffers partial `data:` chunks, and maps Vertex's candidate payloads into OpenAI-style stream events.
5. **Tool Call / `thought_signature` Cache:** An LRU cache persists `call_id → { name, signature }` so Gemini 3's `thought_signature` survives across turns and tool responses are matched back to the correct function name.
6. **Auth Handling:** Detects `401 Unauthorized` and instructs you to re-run `gcloud auth application-default login`.

## 📄 Changelog

See [CHANGELOG.md](./CHANGELOG.md) for a detailed breakdown of what was fixed compared to the original release.
