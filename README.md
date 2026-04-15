# Vertex AI to OpenAI Local Proxy

A lightning-fast, production-grade local proxy that translates OpenAI API requests into Google Vertex AI (Gemini) API requests. 

**🚀 THE $300 FREE CREDIT LIFEHACK:** 
Google Cloud gives **$300 in free credits** to new users to use on Vertex AI, which gives you access to the bleeding-edge `Gemini 3.1 Pro (Thinking)` model. However, premium AI Coding Agents in VS Code (like Kilo Code, Cline, Cursor, or Roo) don't natively support Vertex AI's complex authentication and tool-calling schemas. 

This proxy solves that completely. It sits on your local machine, accepts OpenAI-format API calls from your VS Code extensions, translates them to Google's Vertex format securely, and streams the results back. **This allows you to code with the most expensive, advanced AI models used by senior devs, entirely for free using Google's startup credits.**

Built by [TechBedouin](https://youtube.com/@TechBedouin).

## 🌟 Why this proxy?

Google's Vertex AI provides Enterprise-grade access to the powerful **Gemini 3.1 Pro** model. However, almost all local AI extensions expect to talk to an standard OpenAI API (`/v1/chat/completions`).

This proxy sits on your local machine, accepts OpenAI-format API calls from your extensions, translates them to Google's Vertex format in real-time, and perfectly streams the results back.

### 🔥 Features
- **Full OpenAI API Compatibility:** Drop-in replacement for OpenAI endpoints (`/v1/chat/completions`).
- **Memory-Bridged Tool Calling:** Gemini 3.1 Pro strictly requires cryptographically signed `thought_signature` metadata for multi-turn tool calling. This proxy uses an internal LRU Cache to persist these signatures across REST boundaries, ensuring your Agent doesn't crash mid-task.
- **"God Mode" Local Vision Bypass:** Automatically detects `@filename.png` references in prompts, fetching images straight from your hard drive and encoding them silently to bypass API Base64 chunking limitations.
- **Self-Healing Authentication:** Built-in OAuth 2.0 flow. Run one command to authenticate via browser. The proxy automatically refreshes tokens in the background to ensure sessions never randomly die.

## ⚙️ Installation

1. Clone the repository and install dependencies
```bash
git clone https://github.com/YourName/vertex-openai-proxy.git
cd vertex-openai-proxy
npm install
```

2. Configure your Environment Variables by creating a `.env` file:
```env
# Required Configuration
GOOGLE_CLOUD_PROJECT_ID=your-gcp-project-id
GOOGLE_CLOUD_LOCATION=global
GOOGLE_CLOUD_MODEL_ID=gemini-3.1-pro-preview

# Optional (Auth Defaults)
GOOGLE_CLIENT_ID=your-oauth-client-id
GOOGLE_CLIENT_SECRET=your-oauth-client-secret
```

3. Authenticate with Google Cloud:
```bash
npm run auth
```
This will open your browser. Accept the permissions, and your credentials will be securely saved to your local Application Default Credentials (ADC) path.

4. Start the server:
```bash
npm run start
```
*The proxy will now be listening on `http://localhost:3000`*

## 🤖 Configuring your AI Agents

Once the proxy is running, configure your VS Code Extension or AI tool exactly as if it were OpenAI:

*   **API Provider:** `OpenAI Compatible`
*   **Base URL:** `http://localhost:3000/v1`
*   **API Key:** `sk-anything` (The proxy ignores this; it uses your local OAuth token).
*   **Model Name:** `gemini-3.1-pro-preview` 

### Supported Agents
This proxy is heavily tested and natively supports:
- **Kilo Code**
- **Cline & Roo Code**
- **Aider**
- **Any OpenAI-compatible library (Langchain, LlamaIndex, etc.)**

## 🏗️ Architecture

1. **Request Interceptor:** Captures OpenAI format messages, extracting system prompts, user turns, and tool messages.
2. **Vision Normalizer:** Downloads `http` images or fetches local disk images and packages them into Google's `inlineData` Base64 requirements.
3. **SSE Stream Mapper:** Opens an HTTP connection to `aiplatform.googleapis.com`. As tokens stream back, it maps Vertex's nested candidate payload into OpenAI chunk events (`response.added`, `delta`, `done`).
4. **Auth Watchdog:** Detects `401 Unauthorized` responses and instantly deletes local memory, forcing the very next request to perform a silent background refresh using your `refresh_token`.