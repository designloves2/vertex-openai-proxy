/**
 * Vertex AI Gemini Backend Server
 *
 * This server connects to Google Vertex AI using OAuth authentication.
 * Uses the latest streamGenerateContent API endpoint.
 *
 * Features:
 * - /chat - Simple text chat (legacy format)
 * - /v1/chat/completions - OpenAI-compatible API
 * - /v1/responses - OpenAI Responses API support
 * - Streaming support
 */

require('dotenv').config();
const express = require('express');
const path = require('path');
const fs = require('fs');
const https = require('https');
const os = require('os');
const { GoogleAuth } = require('google-auth-library');

// ============================================================================
// GLOBAL STATE
// ============================================================================

// REQUIRED for Gemini 3.1 Pro: We must store the thoughtSignature corresponding to
// each function call to pass it back in the conversation history, avoiding 400 Errors.
// ENHANCED: LRU memory eviction to prevent infinite memory leak. Max size 1000.
class LRUCache {
    constructor(max = 1000) {
        this.max = max;
        this.cache = new Map();
    }
    has(key) { return this.cache.has(key); }
    get(key) {
        if (!this.cache.has(key)) return undefined;
        const val = this.cache.get(key);
        this.cache.delete(key);
        this.cache.set(key, val);
        return val;
    }
    set(key, value) {
        if (this.cache.has(key)) this.cache.delete(key);
        else if (this.cache.size >= this.max) this.cache.delete(this.cache.keys().next().value);
        this.cache.set(key, value);
    }
}
const toolCallData = new LRUCache(1000); // Stores { name: string, signature?: string }
const toolSignatureByName = new Map(); // Fallback when the OpenAI client changes tool-call IDs
let latestThoughtSignature = null;
const SKIP_THOUGHT_SIGNATURE_VALIDATOR = 'skip_thought_signature_validator';

// --- HELPER: SMART LOGGING (PREVENTS EVENT LOOP FREEZES) ---
function smartTruncate(obj, limit = 1000) {
    if (!obj || typeof obj !== 'object') {
        if (typeof obj === 'string' && obj.length > limit) {
            return obj.substring(0, limit) + `... [TRUNCATED ${obj.length} chars]`;
        }
        return obj;
    }
    if (Array.isArray(obj)) return obj.map(i => smartTruncate(i, limit));

    if (Buffer.isBuffer(obj) || obj instanceof Uint8Array) {
        return `[Binary Data: ${obj.length} bytes]`;
    }

    const newObj = {};
    for (const key in obj) {
        if (Object.prototype.hasOwnProperty.call(obj, key)) {
            newObj[key] = smartTruncate(obj[key], limit);
        }
    }
    return newObj;
}

const DEBUG_DIR = path.join(os.tmpdir(), 'gemini-proxy-debug');
if (!fs.existsSync(DEBUG_DIR)) fs.mkdirSync(DEBUG_DIR, { recursive: true });

// CACHE STATE
let cachedAccessToken = null;
let cachedTokenExpiresAt = 0;

// ============================================================================
// CONFIGURATION
// ============================================================================

const PROJECT_ID = process.env.GOOGLE_CLOUD_PROJECT_ID;
let LOCATION = process.env.GOOGLE_CLOUD_LOCATION || 'global';
if (LOCATION && LOCATION.includes('-3.1-pro')) {
    LOCATION = 'global';
}
const MODEL_ID = process.env.GOOGLE_CLOUD_MODEL_ID || 'gemini-1.5-flash-002';
const PORT = process.env.PORT || 3000;

// HELPERS: Dynamic Model Routing
function resolveVertexModel(requestedModel) {
    const requested = String(requestedModel || '').trim();

    // The OpenAI-compatible client is allowed to select the actual Vertex model.
    // Keep the .env model only as the fallback when no model was supplied.
    if (requested) {
        const aliases = {
            'gpt-4o': 'gemini-3.1-pro',
            'gpt-4o-mini': 'gemini-3.8-flash',
            'Gemini 3.1 Pro (Vision)': 'gemini-3.1-pro'
        };
        return aliases[requested] || requested;
    }

    return MODEL_ID;
}

const SAFETY_SETTINGS = [
    { category: 'HARM_CATEGORY_HARASSMENT', threshold: 'BLOCK_NONE' },
    { category: 'HARM_CATEGORY_HATE_SPEECH', threshold: 'BLOCK_NONE' },
    { category: 'HARM_CATEGORY_SEXUALLY_EXPLICIT', threshold: 'BLOCK_NONE' },
    { category: 'HARM_CATEGORY_DANGEROUS_CONTENT', threshold: 'BLOCK_NONE' },
    { category: 'HARM_CATEGORY_CIVIC_INTEGRITY', threshold: 'BLOCK_NONE' }
];

// ============================================================================
// STREAM HELPERS
// ============================================================================

function safeWrite(res, content) {
    if (res.writableEnded || res.finished) return false;
    try {
        res.write(content);
        return true;
    } catch (e) {
        console.error('[STREAM] safeWrite failed:', e.message);
        return false;
    }
}

function safeEnd(res, content) {
    if (res.writableEnded || res.finished) return;
    try {
        if (content) res.write(content);
        res.end();
    } catch (e) {
        console.error('[STREAM] safeEnd failed:', e.message);
    }
}

// ============================================================================
// CREDENTIALS / GOOGLE APPLICATION DEFAULT CREDENTIALS
// ============================================================================

const googleAuth = new GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/cloud-platform']
});

function getCredentialsPath() {
    const possiblePaths = [
        process.env.GOOGLE_APPLICATION_CREDENTIALS,
        path.join(process.env.APPDATA || '', 'gcloud', 'application_default_credentials.json'),
        path.join(process.env.USERPROFILE || '', 'AppData', 'Roaming', 'gcloud', 'application_default_credentials.json'),
        path.join(process.env.APPDATA || '', 'google-applications', 'application_default_credentials.json'),
        path.join(process.env.USERPROFILE || '', 'AppData', 'Roaming', 'google-applications', 'application_default_credentials.json')
    ].filter(Boolean);

    for (const p of possiblePaths) {
        if (fs.existsSync(p)) return p;
    }
    return null;
}

async function getAccessToken(forceRefresh = false) {
    if (!forceRefresh && cachedAccessToken && Date.now() < cachedTokenExpiresAt) {
        return cachedAccessToken;
    }

    try {
        const client = await googleAuth.getClient();
        const tokenResponse = await client.getAccessToken();
        const accessToken = typeof tokenResponse === 'string'
            ? tokenResponse
            : tokenResponse?.token;

        if (!accessToken) {
            throw new Error('Google ADC did not return an access token');
        }

        cachedAccessToken = accessToken;
        cachedTokenExpiresAt = Date.now() + (50 * 60 * 1000);
        return accessToken;
    } catch (error) {
        cachedAccessToken = null;
        cachedTokenExpiresAt = 0;
        throw new Error(`Google ADC authentication failed: ${error.message}`);
    }
}

// ============================================================================
// GEMINI API CALL
// ============================================================================

async function callGeminiAPI(baseRequestBody, stream = false, customModelId = null, customLocation = null) {
    const accessToken = await getAccessToken();
    const apiEndpoint = 'aiplatform.googleapis.com';

    const targetModel = customModelId || MODEL_ID;
    const targetLocation = customLocation || LOCATION;

    // Switch to stable :generateContent for non-streaming
    const verb = stream ? 'streamGenerateContent' : 'generateContent';
    let apiPath = `/v1/projects/${PROJECT_ID}/locations/${targetLocation}/publishers/google/models/${targetModel}:${verb}`;

    if (stream) {
        apiPath += '?alt=sse';
    }

    return new Promise((resolve, reject) => {
        const postData = JSON.stringify(baseRequestBody);
        const options = {
            hostname: apiEndpoint,
            port: 443,
            path: apiPath,
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${accessToken}`,
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(postData)
            },
            timeout: 60000
        };

        const proxyReq = https.request(options, (proxyRes) => {
            const chunks = [];
            proxyRes.on('data', chunk => chunks.push(chunk));
            proxyRes.on('end', () => {
                const data = Buffer.concat(chunks).toString('utf8');
                if (proxyRes.statusCode === 401) {
                    // Token expired or revoked
                    reject(new Error('401_UNAUTHORIZED'));
                    return;
                }
                try {
                    const parsed = JSON.parse(data);
                    resolve(parsed);
                } catch (e) {
                    reject(new Error(`Failed to parse API response (${proxyRes.statusCode}): ` + data.substring(0, 500)));
                }
            });
        });

        proxyReq.on('error', reject);
        proxyReq.write(postData);
        proxyReq.end();
    });
}

// Wrapper for retry logic
async function callGeminiAPIWithRetry(baseRequestBody, stream = false, customModelId = null, customLocation = null) {
    try {
        return await _doCallGeminiAPI(baseRequestBody, stream, customModelId, customLocation, false);
    } catch (e) {
        if (e.message === '401_UNAUTHORIZED') {
            console.log('[AUTH] Token expired (401). Forcing refresh and retrying...');
            return await _doCallGeminiAPI(baseRequestBody, stream, customModelId, customLocation, true);
        }
        throw e;
    }
}

async function _doCallGeminiAPI(baseRequestBody, stream, targetModel, targetLocation, forceRefresh) {
    const accessToken = await getAccessToken(forceRefresh);
    const apiEndpoint = 'aiplatform.googleapis.com';

    const verb = stream ? 'streamGenerateContent' : 'generateContent';
    let apiPath = `/v1/projects/${PROJECT_ID}/locations/${targetLocation}/publishers/google/models/${targetModel}:${verb}`;

    if (stream) {
        apiPath += '?alt=sse';
    }

    return new Promise((resolve, reject) => {
        const postData = JSON.stringify(baseRequestBody);
        const options = {
            hostname: apiEndpoint,
            port: 443,
            path: apiPath,
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${accessToken}`,
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(postData)
            },
            timeout: 60000
        };

        const proxyReq = https.request(options, (proxyRes) => {
            const chunks = [];
            proxyRes.on('data', chunk => chunks.push(chunk));
            proxyRes.on('end', () => {
                const data = Buffer.concat(chunks).toString('utf8');
                if (proxyRes.statusCode === 401) {
                    reject(new Error('401_UNAUTHORIZED'));
                    return;
                }
                try {
                    const parsed = JSON.parse(data);
                    resolve({ statusCode: proxyRes.statusCode, data: parsed });
                } catch (e) {
                    reject(new Error(`Failed to parse API response (${proxyRes.statusCode}): ` + data.substring(0, 500)));
                }
            });
        });

        proxyReq.on('error', reject);
        proxyReq.write(postData);
        proxyReq.end();
    });
}

// ============================================================================
// EXPRESS SERVER SETUP
// ============================================================================

const app = express();

app.use(express.json({ limit: '50mb' }));

app.use((req, res, next) => {
    console.log(`[${new Date().toISOString()}] ${req.method} ${req.path}`);
    next();
});

// ============================================================================
// HEALTH CHECK ENDPOINT
// ============================================================================

app.get('/health', (req, res) => {
    res.json({
        status: 'ok',
        message: 'Server is running',
        timestamp: new Date().toISOString(),
        configured: !!PROJECT_ID,
        projectId: PROJECT_ID,
        location: LOCATION,
        model: MODEL_ID
    });
});

// ============================================================================
// LEGACY CHAT ENDPOINT
// ============================================================================

app.post('/chat', async (req, res) => {
    try {
        const { prompt } = req.body;

        if (!prompt || typeof prompt !== 'string' || prompt.trim().length === 0) {
            return res.status(400).json({
                error: 'Invalid prompt',
                message: 'Prompt must be a non-empty string'
            });
        }

        console.log(`[CHAT] Sending request to Gemini with model: ${MODEL_ID} (default)`);

        const accessToken = await getAccessToken();

        const apiEndpoint = 'aiplatform.googleapis.com';
        const apiPath = `/v1/projects/${PROJECT_ID}/locations/${LOCATION}/publishers/google/models/${MODEL_ID}:streamGenerateContent`;

        const requestBody = {
            contents: {
                role: 'user',
                parts: [{ text: prompt }]
            },
            generationConfig: {
                temperature: 0.9,
                topP: 1,
                topK: 40,
                maxOutputTokens: 32768,
                thinkingConfig: { thinkingLevel: "high" }
            }
        };

        const response = await new Promise((resolve, reject) => {
            const postData = JSON.stringify(requestBody);

            const options = {
                hostname: apiEndpoint,
                port: 443,
                path: apiPath,
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(postData)
                },
                timeout: 60000
            };

            const proxyReq = https.request(options, (proxyRes) => {
                const chunks = [];
                proxyRes.on('data', chunk => chunks.push(chunk));
                proxyRes.on('end', () => {
                    const data = Buffer.concat(chunks).toString('utf8');
                    try {
                        const parsed = JSON.parse(data);
                        resolve(parsed);
                    } catch (e) {
                        reject(new Error('Failed to parse API response: ' + data.substring(0, 500)));
                    }
                });
            });

            proxyReq.on('error', reject);
            proxyReq.write(postData);
            proxyReq.end();
        });

        if (response.error) {
            console.error('[CHAT] API Error:', response.error);
            return res.status(400).json({
                error: 'AI API Error',
                message: response.error.message || 'Unknown error'
            });
        }

        let reply = '';
        if (Array.isArray(response)) {
            response.forEach(chunk => {
                if (chunk.candidates && chunk.candidates.length > 0) {
                    const candidate = chunk.candidates[0];
                    if (candidate.content && candidate.content.parts) {
                        candidate.content.parts.forEach(part => {
                            if (part.thought) {
                                console.log('[CHAT] Thought:', part.text?.substring(0, 100) + '...');
                                return;
                            }
                            if (part.text) reply += part.text;
                        });
                    }
                }
            });
        } else if (response.candidates && response.candidates.length > 0) {
            const candidate = response.candidates[0];
            if (candidate.content && candidate.content.parts) {
                reply = candidate.content.parts
                    .map(part => part.text || '')
                    .join('');
            } else if (candidate.output) {
                reply = candidate.output;
            }
        } else if (response.responses && response.responses.length > 0) {
            response.responses.forEach(r => {
                if (r.candidates && r.candidates.length > 0) {
                    const part = r.candidates[0]?.content?.parts?.[0]?.text;
                    if (part) reply += part;
                }
            });
        }

        console.log(`[CHAT] Received response: "${reply.substring(0, 50)}${reply.length > 50 ? '...' : ''}"`);

        res.json({
            reply: reply || 'No response generated'
        });

    } catch (error) {
        console.error('[CHAT] Error:', error.message);

        if (error.message.includes('credentials')) {
            return res.status(500).json({
                error: 'Authentication failed',
                message: 'Please run: gcloud auth application-default login'
            });
        }

        res.status(500).json({
            error: 'AI processing failed',
            message: error.message
        });
    }
});

// ============================================================================
// OPENAI -> GEMINI MULTIMODAL (data URIs + fetchable http(s) image URLs)
// ============================================================================

const MAX_IMAGE_FETCH_BYTES = 20 * 1024 * 1024;
const IMAGE_FETCH_TIMEOUT_MS = 45000;

function normalizeGeminiImageMime(mime) {
    let m = String(mime || 'image/png').split(';')[0].trim().toLowerCase();
    if (m === 'image/jpg') m = 'image/jpeg';
    return m || 'image/png';
}

function normalizeInlineDataPart(part) {
    if (part && part.inlineData && part.inlineData.mimeType) {
        part.inlineData.mimeType = normalizeGeminiImageMime(part.inlineData.mimeType);
    }
    return part;
}

function tryRawBase64ImagePayload(s) {
    const cleaned = String(s).trim().replace(/\s/g, '');
    if (cleaned.length < 80) return null;
    if (/^https?:\/\//i.test(cleaned) || cleaned.startsWith('data:')) return null;
    if (!/^[A-Za-z0-9+/]+=*$/.test(cleaned)) return null;
    let buf;
    try {
        buf = Buffer.from(cleaned, 'base64');
    } catch {
        return null;
    }
    const mimeType = sniffImageMime(buf) || 'image/png';
    return normalizeInlineDataPart({ inlineData: { mimeType, data: buf.toString('base64') } });
}

function parseDataUriImage(url) {
    const match = String(url).trim().match(/^data:(.+?);base64,(.+)$/s);
    if (!match) return null;
    const mimeType = match[1].split(';')[0].trim() || 'image/png';
    const data = match[2].replace(/\s/g, '');
    if (!data) return null;
    return normalizeInlineDataPart({ inlineData: { mimeType, data } });
}

function sniffImageMime(buf) {
    if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
    if (buf.length >= 8 && buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47) return 'image/png';
    if (buf.length >= 6 && buf[0] === 0x47 && buf[1] === 0x49 && buf[2] === 0x46) return 'image/gif';
    if (buf.length >= 12 && buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP') return 'image/webp';
    return null;
}

async function fetchHttpImageAsInlineData(urlString) {
    let parsed;
    try {
        parsed = new URL(urlString);
    } catch {
        return null;
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
        return null;
    }

    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), IMAGE_FETCH_TIMEOUT_MS);
    try {
        const res = await fetch(urlString, {
            signal: ac.signal,
            redirect: 'follow',
            headers: { Accept: 'image/*,application/octet-stream;q=0.8,*/*;q=0.5' }
        });
        if (!res.ok) {
            console.warn(`[V1/CHAT] Image fetch HTTP ${res.status}: ${urlString.slice(0, 120)}`);
            return null;
        }
        const cl = res.headers.get('content-length');
        if (cl && Number(cl) > MAX_IMAGE_FETCH_BYTES) {
            console.warn('[V1/CHAT] Image Content-Length exceeds limit');
            return null;
        }
        const buf = Buffer.from(await res.arrayBuffer());
        if (buf.length > MAX_IMAGE_FETCH_BYTES) {
            console.warn('[V1/CHAT] Image body exceeds limit');
            return null;
        }
        let mimeType = (res.headers.get('content-type') || '').split(';')[0].trim().toLowerCase();
        if (!mimeType.startsWith('image/')) {
            mimeType = sniffImageMime(buf) || 'image/png';
        }
        return normalizeInlineDataPart({ inlineData: { mimeType, data: buf.toString('base64') } });
    } catch (e) {
        console.warn('[V1/CHAT] Image fetch failed:', e.message, urlString.slice(0, 100));
        return null;
    } finally {
        clearTimeout(timer);
    }
}

async function resolveOpenAIImageUrl(url) {
    const fromRaw = tryRawBase64ImagePayload(url);
    if (fromRaw) return fromRaw;
    const fromData = parseDataUriImage(url);
    if (fromData) return fromData;
    return fetchHttpImageAsInlineData(url);
}

/**
 * GOD MODE: Disk Grabber
 */
async function tryAttachLocalFilesByTextReference(text) {
    const fileMatches = text.match(/@[a-zA-Z0-9_\-\.]+\.(png|jpg|jpeg|webp)/gi);
    if (!fileMatches) return [];

    const attachedParts = [];
    for (const match of fileMatches) {
        const filename = match.substring(1).trim(); // Remove '@'
        const filePath = path.join(process.cwd(), filename);

        if (fs.existsSync(filePath)) {
            try {
                const buf = fs.readFileSync(filePath);
                const ext = path.extname(filename).toLowerCase();
                let mimeType = 'image/png';
                if (ext === '.jpg' || ext === '.jpeg') mimeType = 'image/jpeg';
                else if (ext === '.webp') mimeType = 'image/webp';

                console.log(`[GOD_MODE] Auto-attached ${filename} from disk! Bypass successful.`);
                attachedParts.push(normalizeInlineDataPart({
                    inlineData: {
                        mimeType,
                        data: buf.toString('base64')
                    }
                }));
            } catch (e) {
                console.warn(`[GOD_MODE] Failed to read ${filename}:`, e.message);
            }
        }
    }
    return attachedParts;
}

async function openAiMessagesToGeminiContents(messages) {
    const contents = [];
    let systemInstructionText = '';
    let imageUrlsSeen = 0;
    let imageUrlsEmbedded = 0;
    let inlinedImagesInPayload = false;
    let signatureFallbackCount = 0;

    for (let i = 0; i < messages.length; i++) {
        const msg = messages[i];
        let msgText = '';
        let imageParts = [];

        if (Array.isArray(msg.content)) {
            msgText = msg.content.filter(c => c.type === 'text' || c.text).map(c => c.text || '').join('\n');
            const imageContents = msg.content.filter(c => c.type === 'image_url' && c.image_url && c.image_url.url);
            for (const img of imageContents) {
                imageUrlsSeen++;
                const inline = await resolveOpenAIImageUrl(String(img.image_url.url).trim());
                if (inline) {
                    imageParts.push(inline);
                    imageUrlsEmbedded++;
                    inlinedImagesInPayload = true;
                }
            }
        } else {
            msgText = typeof msg.content === 'string' ? msg.content : JSON.stringify(msg.content || '');
        }

        if (msg.role === 'system' || msg.role === 'developer') {
            let cleanedText = msgText.replace(/The current model configuration does not support image input/gi, '[VISION ENABLED]');
            cleanedText = cleanedText.replace(/I cannot see images/gi, 'I can see images');
            systemInstructionText += (systemInstructionText ? '\n\n' : '') + cleanedText;
            continue;
        }

        if (msg.role === 'user') {
            const parts = [];
            if (msgText) parts.push({ text: msgText });
            if (imageParts.length > 0) parts.push(...imageParts);
            if (msgText && imageParts.length === 0) {
                const diskParts = await tryAttachLocalFilesByTextReference(msgText);
                if (diskParts.length > 0) { parts.push(...diskParts); inlinedImagesInPayload = true; }
            }
            if (parts.length === 0) parts.push({ text: ' ' });

            contents.push({ role: 'user', parts });
        } else if (msg.role === 'assistant') {
            const parts = [];
            if (msgText) parts.push({ text: msgText });

            if (msg.tool_calls && msg.tool_calls.length > 0) {
                for (const tc of msg.tool_calls) {
                    const funcName = tc.function.name;
                    let funcArgs;
                    try {
                        funcArgs = typeof tc.function.arguments === 'string' ? JSON.parse(tc.function.arguments || '{}') : tc.function.arguments;
                    } catch (e) {
                        console.warn(`[V1/CHAT] Failed to parse tool_call arguments for ${funcName}:`, e.message);
                        funcArgs = {};
                    }
                    // RESTORE: Look up the signature from our internal toolCallData Map
                    const stored = toolCallData.get(tc.id) || {};
                    const fallbackSignature =
                        stored.signature ||
                        toolSignatureByName.get(funcName) ||
                        null;

                    const callPart = { functionCall: { name: funcName, args: funcArgs } };

                    // Gemini 3 requires a signature on every replayed functionCall part. When we
                    // can't restore the real one (server restarted and lost the in-memory cache,
                    // history came from another model/client, tool-call ids changed), Google's
                    // documented escape hatch is this dummy value; without it the request 400s.
                    if (fallbackSignature) {
                        callPart.thought_signature = fallbackSignature;
                    } else {
                        callPart.thought_signature = SKIP_THOUGHT_SIGNATURE_VALIDATOR;
                        signatureFallbackCount++;
                    }

                    parts.push(callPart);
                }
            }
            if (parts.length > 0) contents.push({ role: 'model', parts });
        } else if (msg.role === 'tool') {
            // FIX: Prevent creating stacked 'user' turns incorrectly
            let lastContent = contents[contents.length - 1];
            if (!lastContent || lastContent.role !== 'user') {
                lastContent = { role: 'user', parts: [] };
                contents.push(lastContent);
            }

            const stored = toolCallData.get(msg.tool_call_id) || {};
            const funcName = msg.name || stored.name || 'unknown_function';

            let parsedResponse;
            try {
                parsedResponse = typeof msg.content === 'string' ? JSON.parse(msg.content) : msg.content;
                if (typeof parsedResponse !== 'object' || parsedResponse === null || Array.isArray(parsedResponse)) parsedResponse = { result: parsedResponse };
            } catch (e) {
                parsedResponse = { result: msg.content };
            }

            lastContent.parts.push({
                functionResponse: {
                    name: funcName,
                    response: parsedResponse
                }
            });
            // Ensure thoughtSignature is passed back if it exists for this turn sequence
            if (stored.signature) {
                // Gemini API expects the response to correspond to a turn.
                // We keep the signature in memory to help the next tool-leg if needed.
            }
        }
    }

    if (signatureFallbackCount > 0) {
        console.warn(`[V1/CHAT] ${signatureFallbackCount} replayed tool call(s) had no stored thought signature; using skip_thought_signature_validator.`);
    }

    if (imageUrlsSeen > imageUrlsEmbedded) {
        return { contents: [], systemInstructionText: '', imageLoadError: 'Could not load images. Base64 expected.' };
    }

    if (inlinedImagesInPayload && !systemInstructionText.includes('VISION SYSTEM')) {
        systemInstructionText = "VISION SYSTEM ACTIVATED: You can see images.\n" + (systemInstructionText || "");
    }

    return { contents, systemInstructionText, imageLoadError: null, inlinedImagesInPayload };
}

app.post('/v1/chat/completions', async (req, res) => {
    try {
        const { messages, model: requestedModel, temperature = 0.9, max_tokens, tools, tool_choice } = req.body;

        // Dynamic Routing
        const MODEL_ID_TO_USE = resolveVertexModel(requestedModel);
        const LOCATION_TO_USE = LOCATION;

        // Image models (Imagen / Gemini *-image) are routed to image generation.
        if (isImageModel(MODEL_ID_TO_USE) && Array.isArray(messages) && messages.length) {
            console.log(`[V1/CHAT] Image model ${MODEL_ID_TO_USE}: routing to image generation`);
            return await handleImageModelChat(req, res, MODEL_ID_TO_USE);
        }

        // FIX: Respect client streaming request
        const stream = req.body.stream === true;

        if (!messages || !Array.isArray(messages) || messages.length === 0) {
            return res.status(400).json({
                error: {
                    message: 'messages is required and must be a non-empty array',
                    type: 'invalid_request_error',
                    param: null,
                    code: null
                }
            });
        }

        console.log(`[V1/CHAT] Stream: ${stream}, Messages: ${messages.length}, Tools: ${tools ? tools.length : 0}`);

        // Write to system temp folder with Smart Truncation to prevent hangs and reboot loops
        const safeReq = smartTruncate(req.body);
        fs.writeFileSync(path.join(DEBUG_DIR, 'last_request.json'), JSON.stringify(safeReq, null, 2));

        if (process.env.VISION_DEBUG === '1') {
            const types = messages.map(m => m.role + ': ' + (Array.isArray(m.content) ? ('array of ' + m.content.map(c => c.type).join(',')) : typeof m.content)).join(' | ');
            console.log(`[VISION_DEBUG] user content block types: ${types}`);
        }

        const { contents, systemInstructionText, imageLoadError, inlinedImagesInPayload } = await openAiMessagesToGeminiContents(messages);
        if (stream && contents.some(c => c.role === 'model' && c.parts?.some(p => p.functionCall))) {
            console.log('[V1/CHAT] Model tool-call signatures:', contents
                .filter(c => c.role === 'model')
                .flatMap(c => c.parts || [])
                .filter(p => p.functionCall)
                .map(p => ({
                    name: p.functionCall.name,
                    hasThoughtSignature: !!p.thought_signature
                })));
        }
        if (imageLoadError) {
            return res.status(400).json({
                error: {
                    message: imageLoadError,
                    type: 'invalid_request_error',
                    param: 'messages',
                    code: null
                }
            });
        }

        // FIX: Utilize actual max_tokens from request
        const generationConfig = {
            maxOutputTokens: max_tokens || 32768
        };

        const isGemini3Flash = /^gemini-3\.\d+-flash$/i.test(MODEL_ID_TO_USE);
        if (!isGemini3Flash) {
            generationConfig.temperature = temperature;
            generationConfig.topP = 1;
            generationConfig.topK = 40;
        }

        if (!supportsThinkingLevel(MODEL_ID_TO_USE)) {
            // thinkingLevel is Gemini 3+ only; older models (2.5 etc.) reject it with 400.
        } else if (!inlinedImagesInPayload && isGemini3Flash) {
            generationConfig.thinkingConfig = { thinkingLevel: "high" };
        } else if (!inlinedImagesInPayload) {
            generationConfig.thinkingConfig = { thinkingLevel: "high" };
        } else {
            console.log(`[V1/CHAT] Images in request: omitting thinkingConfig ...`);
        }

        const baseRequestBody = {
            contents: contents,
            generationConfig: generationConfig,
            safetySettings: SAFETY_SETTINGS
        };

        if (tools && tools.length > 0) {
            baseRequestBody.tools = [{
                functionDeclarations: tools
                    .filter(t => t.type === 'function' && t.function)
                    .map(t => {
                        const func = JSON.parse(JSON.stringify(t.function));
                        if (func.parameters) {
                            func.parameters = sanitizeSchema(func.parameters);
                        }
                        return func;
                    })
            }];

            if (tool_choice) {
                if (tool_choice === 'none') {
                    baseRequestBody.toolConfig = { functionCallingConfig: { mode: 'NONE' } };
                } else if (tool_choice === 'auto') {
                    baseRequestBody.toolConfig = { functionCallingConfig: { mode: 'AUTO' } };
                } else if (tool_choice === 'required') {
                    baseRequestBody.toolConfig = { functionCallingConfig: { mode: 'ANY' } };
                } else if (typeof tool_choice === 'object' && tool_choice.type === 'function') {
                    baseRequestBody.toolConfig = {
                        functionCallingConfig: {
                            mode: 'ANY',
                            allowedFunctionNames: [tool_choice.function.name]
                        }
                    };
                }
            }
        }

        if (systemInstructionText) {
            baseRequestBody.systemInstruction = {
                role: 'system',
                parts: [{ text: systemInstructionText }]
            };
        }

        if (stream) {
            // ===== STREAMING RESPONSE =====
            const MAX_TRANSIENT_RETRIES = 3;
            const sendStreamRequest = async (isRetryAfterAuthRefresh = false, transientRetryCount = 0) => {
            const accessToken = await getAccessToken(isRetryAfterAuthRefresh);
            const apiEndpoint = 'aiplatform.googleapis.com';
            const apiPath = `/v1/projects/${PROJECT_ID}/locations/${LOCATION_TO_USE}/publishers/google/models/${MODEL_ID_TO_USE}:streamGenerateContent?alt=sse`;
            const postData = JSON.stringify(baseRequestBody);

            const options = {
                hostname: apiEndpoint,
                port: 443,
                path: apiPath,
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${accessToken}`,
                    'Content-Type': 'application/json',
                    'Content-Length': Buffer.byteLength(postData)
                },
                timeout: 90000
            };

            const proxyReq = https.request(options, (proxyRes) => {
                if (proxyRes.statusCode !== 200) {
                    let errBody = '';
                    proxyRes.setEncoding('utf8');
                    proxyRes.on('data', chunk => errBody += chunk);
                    proxyRes.on('end', async () => {
                        if (proxyRes.statusCode === 401 && !isRetryAfterAuthRefresh) {
                            console.log('[V1/STREAM] Token expired (401). Forcing refresh and retrying...');
                            try {
                                await sendStreamRequest(true);
                            } catch (retryErr) {
                                if (!res.headersSent) {
                                    res.status(500).json({ error: { message: retryErr.message, type: 'api_error' } });
                                } else {
                                    safeEnd(res, `data: ${JSON.stringify({ error: { message: retryErr.message } })}\n\n`);
                                }
                            }
                            return;
                        }
                        if ((proxyRes.statusCode === 429 || proxyRes.statusCode >= 500) && transientRetryCount < MAX_TRANSIENT_RETRIES) {
                            const nextRetryCount = transientRetryCount + 1;
                            const RETRY_DELAYS_MS = [2000, 3000, 5000];
                            const delayMs = RETRY_DELAYS_MS[transientRetryCount]; // 2s, 3s, 5s
                            console.warn(`[V1/STREAM] Gemini HTTP ${proxyRes.statusCode} (attempt ${nextRetryCount}/${MAX_TRANSIENT_RETRIES}). Retrying in ${delayMs}ms...`);
                            setTimeout(() => {
                                sendStreamRequest(isRetryAfterAuthRefresh, nextRetryCount).catch((retryErr) => {
                                    if (!res.headersSent) {
                                        res.status(500).json({ error: { message: retryErr.message, type: 'api_error' } });
                                    } else {
                                        safeEnd(res, `data: ${JSON.stringify({ error: { message: retryErr.message } })}\n\n`);
                                    }
                                });
                            }, delayMs);
                            return;
                        }
                        console.error('[V1/STREAM] Gemini HTTP error:', proxyRes.statusCode, errBody.substring(0, 2000));
                        if (!res.headersSent) {
                            res.status(proxyRes.statusCode).json({
                                error: {
                                    message: errBody || `Gemini API returned HTTP ${proxyRes.statusCode}`,
                                    type: 'api_error',
                                    code: proxyRes.statusCode
                                }
                            });
                        } else {
                            safeEnd(res, `data: ${JSON.stringify({
                                error: { message: errBody || `Gemini API returned HTTP ${proxyRes.statusCode}` }
                            })}\n\n`);
                        }
                    });
                    return;
                }

                res.writeHead(200, {
                    'Content-Type': 'text/event-stream; charset=utf-8',
                    'Cache-Control': 'no-cache, no-transform',
                    'Connection': 'keep-alive',
                    'Access-Control-Allow-Origin': '*',
                    'X-Accel-Buffering': 'no'
                });
                if (res.flushHeaders) res.flushHeaders();

                let dataBuffer = '';
                let hasStreamedToolCall = false;
                let sawAnyCandidate = false;
                let sawAnyText = false;

                proxyRes.setEncoding('utf8');

                const emitText = (textChunk) => {
                    if (!textChunk) return;
                    sawAnyText = true;
                    const chunkObj = {
                        id: `chatcmpl-${Date.now()}`,
                        object: 'chat.completion.chunk',
                        created: Math.floor(Date.now() / 1000),
                        model: requestedModel || MODEL_ID_TO_USE,
                        choices: [{
                            delta: { role: 'assistant', content: textChunk },
                            index: 0,
                            finish_reason: null
                        }]
                    };
                    safeWrite(res, `data: ${JSON.stringify(chunkObj)}\n\n`);
                };

                const emitToolCall = (functionCall, thoughtSignature = null) => {
                    if (!functionCall?.name) return;
                    hasStreamedToolCall = true;
                    const callId = 'call_' + Math.random().toString(36).slice(2, 11);
                    const args = typeof functionCall.args === 'string'
                        ? functionCall.args
                        : JSON.stringify(functionCall.args || {});

                    const signature = thoughtSignature || functionCall.thoughtSignature || functionCall.thought_signature || null;

                    toolCallData.set(callId, {
                        name: functionCall.name,
                        signature
                    });

                    // Gemini 3 parallel/sequential function calling may expose the
                    // signature only on the first function-call part. Keep a fallback
                    // by function name in case the OpenAI client changes the call ID.
                    if (signature) {
                        latestThoughtSignature = signature;
                        toolSignatureByName.set(functionCall.name, signature);
                        console.log(`[V1/STREAM] Tool signature captured: ${functionCall.name}`);
                    }

                    const chunkObj = {
                        id: `chatcmpl-${Date.now()}`,
                        object: 'chat.completion.chunk',
                        created: Math.floor(Date.now() / 1000),
                        model: requestedModel || MODEL_ID_TO_USE,
                        choices: [{
                            delta: {
                                role: 'assistant',
                                tool_calls: [{
                                    index: 0,
                                    id: callId,
                                    type: 'function',
                                    function: {
                                        name: functionCall.name,
                                        arguments: args
                                    }
                                }]
                            },
                            index: 0,
                            finish_reason: null
                        }]
                    };
                    safeWrite(res, `data: ${JSON.stringify(chunkObj)}\n\n`);
                };

                // Vertex AI alt=sse can deliver multiple JSON objects as consecutive
                // data lines without a blank-line separator. Parse each complete data line
                // independently, while buffering a partial line across network chunks.
                const processDataLine = (line) => {
                    const trimmed = String(line).trim();
                    if (!trimmed.startsWith('data:')) return;

                    const jsonStr = trimmed.startsWith('data: ')
                        ? trimmed.slice(6).trim()
                        : trimmed.slice(5).trim();

                    if (!jsonStr || jsonStr === '[DONE]') return;

                    let parsed;
                    try {
                        parsed = JSON.parse(jsonStr);
                    } catch (e) {
                        console.warn(
                            '[V1/STREAM] Could not parse SSE data line:',
                            jsonStr.substring(0, 300)
                        );
                        return;
                    }

                    if (parsed.error) {
                        console.error('[V1/STREAM] Gemini stream error:', parsed.error);
                        return;
                    }

                    const candidates = parsed.candidates || [];
                    if (candidates.length) sawAnyCandidate = true;

                    for (const candidate of candidates) {
                        const parts = candidate?.content?.parts || [];

                        for (const part of parts) {
                            if (part.thought) continue;

                            if (part.text) {
                                emitText(part.text);
                            }

                            if (part.functionCall) {
                                const thoughtSignature =
                                    part.thought_signature ||
                                    part.thoughtSignature ||
                                    latestThoughtSignature ||
                                    null;
                                emitToolCall(part.functionCall, thoughtSignature);
                            }
                        }
                    }
                };

                let sseLineBuffer = '';

                proxyRes.on('data', (chunk) => {
                    sseLineBuffer += chunk;

                    // Normalize CRLF/CR to LF.
                    sseLineBuffer = sseLineBuffer.replace(/\r\n/g, '\n').replace(/\r/g, '\n');

                    let newlineIndex;
                    while ((newlineIndex = sseLineBuffer.indexOf('\n')) !== -1) {
                        const line = sseLineBuffer.slice(0, newlineIndex);
                        sseLineBuffer = sseLineBuffer.slice(newlineIndex + 1);
                        processDataLine(line);
                    }
                });

                proxyRes.on('end', () => {
                    if (dataBuffer.trim()) processEvent(dataBuffer);

                    console.log(`[V1/STREAM] Completed. Candidate=${sawAnyCandidate}, Text=${sawAnyText}, ToolCall=${hasStreamedToolCall}`);

                    const finishChunkObj = {
                        id: `chatcmpl-${Date.now()}`,
                        object: 'chat.completion.chunk',
                        created: Math.floor(Date.now() / 1000),
                        model: requestedModel || MODEL_ID_TO_USE,
                        choices: [{
                            delta: {},
                            index: 0,
                            finish_reason: hasStreamedToolCall ? 'tool_calls' : 'stop'
                        }]
                    };

                    safeWrite(res, `data: ${JSON.stringify(finishChunkObj)}\n\n`);
                    safeWrite(res, 'data: [DONE]\n\n');
                    safeEnd(res);
                });

                proxyRes.on('error', (err) => {
                    console.error('[V1/STREAM] Response error:', err.message);
                    safeEnd(res);
                });
            });

            proxyReq.setTimeout(90000, () => {
                console.error('[V1/STREAM] Vertex request timed out after 90s');
                proxyReq.destroy(new Error('Vertex request timed out after 90 seconds'));
            });

            proxyReq.on('error', (err) => {
                console.error('[V1/STREAM] Request error:', err.message);
                safeEnd(res);
            });

            proxyReq.write(postData);
            proxyReq.end();
            };

            await sendStreamRequest(false);

        } else {
            // ===== NON-STREAMING RESPONSE =====
            const response = await callGeminiAPI(baseRequestBody, false, MODEL_ID_TO_USE, LOCATION_TO_USE);

            if (response.error) {
                console.error('[V1/CHAT] API Error:', response.error);
                return res.status(400).json({
                    error: {
                        message: response.error.message || 'Unknown error',
                        type: 'api_error',
                        code: response.error.code
                    }
                });
            }

            // Handle response - could be array or object depending on streaming
            let reply = '';
            let toolCalls = null;

            // Check if response is an array (streaming format returns array of chunks)
            if (Array.isArray(response)) {
                // Streaming response - extract text from all chunks
                response.forEach(chunk => {
                    if (chunk.candidates && chunk.candidates.length > 0) {
                        const candidate = chunk.candidates[0];
                        if (candidate.content && candidate.content.parts) {
                            candidate.content.parts.forEach(part => {
                                // Skip thought parts for now (internal reasoning)
                                if (part.thought) {
                                    console.log('[V1/CHAT] Thought:', part.text?.substring(0, 100) + '...');
                                    return;
                                }
                                if (part.functionCall) {
                                    if (!toolCalls) toolCalls = [];
                                    const callId = 'call_' + Math.random().toString(36).substr(2, 9);

                                    // FIX: use correct cache mechanism
                                    toolCallData.set(callId, {
                                        name: part.functionCall.name,
                                        signature: part.thoughtSignature || null
                                    });

                                    toolCalls.push({
                                        id: callId,
                                        type: 'function',
                                        function: {
                                            name: part.functionCall.name,
                                            arguments: typeof part.functionCall.args === 'string' ? part.functionCall.args : JSON.stringify(part.functionCall.args || {})
                                        }
                                    });
                                }
                                if (part.text) reply += part.text;
                            });
                        }
                    }
                });
            } else if (response.candidates && response.candidates.length > 0) {
                // Non-streaming response - single object
                const candidate = response.candidates[0];
                if (candidate.content && candidate.content.parts) {
                    // Debug: log the raw parts structure
                    console.log('[V1/CHAT] Raw response parts:', JSON.stringify(candidate.content.parts, null, 2).substring(0, 1500));

                    // First try: extract only non-thought text (correct per docs)
                    reply = candidate.content.parts
                        .filter(part => !part.thought && !part.functionCall)
                        .map(part => part.text || '')
                        .join('');

                    const callPart = candidate.content.parts.find(p => p.functionCall);
                    if (callPart) {
                        const callId = 'call_' + Math.random().toString(36).substr(2, 9);

                        // FIX: use correct cache mechanism
                        toolCallData.set(callId, {
                            name: callPart.functionCall.name,
                            signature: callPart.thought_signature || callPart.thoughtSignature || null
                        });

                        toolCalls = [{
                            id: callId,
                            type: 'function',
                            function: {
                                name: callPart.functionCall.name,
                                arguments: typeof callPart.functionCall.args === 'string' ? callPart.functionCall.args : JSON.stringify(callPart.functionCall.args || {})
                            }
                        }];
                    }

                    // Fallback: if empty, extract ALL text (handles multi-turn edge case)
                    if (!reply && !toolCalls) {
                        console.log('[V1/CHAT] Fallback: extracting from all parts including thoughts');
                        reply = candidate.content.parts
                            .map(part => part.text || '')
                            .join('');
                    }
                } else if (candidate.output) {
                    reply = candidate.output;
                }
            } else if (response.responses && response.responses.length > 0) {
                // Alternative format
                response.responses.forEach(r => {
                    if (r.candidates && r.candidates.length > 0) {
                        const part = r.candidates[0]?.content?.parts?.[0]?.text;
                        if (part) reply += part;
                    }
                });
            }

            console.log(`[V1/CHAT] Received response: "${reply.substring(0, 50)}${reply.length > 50 ? '...' : ''}"`);

            res.json({
                id: `chatcmpl-${Date.now()}`,
                object: 'chat.completion',
                created: Math.floor(Date.now() / 1000),
                model: requestedModel || MODEL_ID_TO_USE,
                choices: [{
                    index: 0,
                    message: {
                        role: 'assistant',
                        content: reply || (toolCalls ? null : 'No response generated'),
                        tool_calls: toolCalls
                    },
                    finish_reason: toolCalls ? 'tool_calls' : 'stop'
                }],
                usage: {
                    prompt_tokens: 0,
                    completion_tokens: 0,
                    total_tokens: 0
                }
            });
        }

    } catch (error) {
        console.error('[V1/CHAT] Error:', error.message);

        if (error.message.includes('credentials')) {
            return res.status(500).json({
                error: {
                    message: 'Authentication failed. Please run: gcloud auth application-default login',
                    type: 'authentication_error'
                }
            });
        }

        res.status(500).json({
            error: {
                message: error.message,
                type: 'api_error',
                code: 'internal_error'
            }
        });
    }
});

// ============================================================================
// OPENAI RESPONSES API ENDPOINT: /v1/responses
// ============================================================================

// HELPER: Sanitize JSON Schema for Gemini (strips unsupported keys like $schema, exclusiveMinimum)
function sanitizeSchema(schema) {
    if (!schema || typeof schema !== 'object') return schema;
    const allowedKeys = ['type', 'properties', 'required', 'items', 'description', 'enum', 'format'];
    const result = {};
    for (const key of allowedKeys) {
        if (schema[key] !== undefined) {
            if (key === 'properties' && schema.properties && typeof schema.properties === 'object') {
                result.properties = {};
                for (const prop in schema.properties) {
                    result.properties[prop] = sanitizeSchema(schema.properties[prop]);
                }
            } else if (key === 'items' && schema.items) {
                result.items = sanitizeSchema(schema.items);
            } else {
                result[key] = schema[key];
            }
        }
    }
    if (!result.type && result.properties) result.type = 'object';
    return result;
}

app.post('/v1/responses', async (req, res) => {
    try {
        const { model: requestedModel, instructions, input, tools, temperature = 0.9, max_output_tokens, stream } = req.body;

        // Dynamic Routing
        const MODEL_ID_TO_USE = resolveVertexModel(requestedModel);
        const LOCATION_TO_USE = LOCATION;

        // --- Conversion from Responses API to Chat format ---
        const messages = [];
        if (instructions) messages.push({ role: 'system', content: instructions });

        if (typeof input === 'string') {
            messages.push({ role: 'user', content: input });
        } else if (Array.isArray(input)) {
            for (const item of input) {
                if (item.role === 'user' || item.role === 'system' || item.role === 'developer') {
                    const role = item.role === 'developer' ? 'system' : item.role;
                    if (typeof item.content === 'string') {
                        messages.push({ role, content: item.content });
                    } else if (Array.isArray(item.content)) {
                        const parts = [];
                        for (const part of item.content) {
                            if (part.type === 'input_text') parts.push({ type: 'text', text: part.text });
                            else if (part.type === 'input_image') {
                                const url = (part.image_url && typeof part.image_url === 'object') ? part.image_url.url : (part.image_url || part.url || '');
                                if (url) parts.push({ type: 'image_url', image_url: { url } });
                            } else if (part.type === 'input_file' && part.file_data) {
                                parts.push({ type: 'image_url', image_url: { url: part.file_data } });
                            }
                        }
                        messages.push({ role, content: parts.length === 1 && parts[0].type === 'text' ? parts[0].text : parts });
                    }
                } else if (item.type === 'message' && item.role === 'assistant') {
                    let text = '';
                    if (Array.isArray(item.content)) {
                        text = item.content.filter(c => c.type === 'output_text').map(c => c.text).join('');
                    }
                    messages.push({ role: 'assistant', content: text || '' });
                } else if (item.type === 'function_call') {
                    messages.push({
                        role: 'assistant', content: null,
                        tool_calls: [{
                            id: item.call_id || ('call_' + Math.random().toString(36).substr(2, 9)),
                            type: 'function',
                            function: { name: item.name, arguments: typeof item.arguments === 'string' ? item.arguments : JSON.stringify(item.arguments || {}) }
                        }]
                    });
                } else if (item.type === 'function_call_output') {
                    messages.push({ role: 'tool', tool_call_id: item.call_id, name: item.name || 'unknown_function', content: typeof item.output === 'string' ? item.output : JSON.stringify(item.output || '') });
                }
            }
        }

        const finalMessages = messages.length > 0 ? messages : (req.body.messages || input || []);
        console.log(`[V1/RESP] Stream: ${!!stream}, Messages: ${finalMessages.length}`);

        const generateId = (prefix) => {
            const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
            let r = ''; for (let i = 0; i < 24; i++) r += chars.charAt(Math.floor(Math.random() * chars.length));
            return prefix + r;
        };

        const respId = generateId('resp_');
        const msgId = generateId('msg_');

        if (stream) {
            res.writeHead(200, {
                'Content-Type': 'text/event-stream',
                'Cache-Control': 'no-cache',
                'Connection': 'keep-alive',
                'Access-Control-Allow-Origin': '*',
                'X-Accel-Buffering': 'no'
            });
            if (res.flushHeaders) res.flushHeaders();

            const sendEvent = (event, data) => {
                const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
                console.log(`[V1/RESP] -> ${event}:`, JSON.stringify(data).substring(0, 80) + (JSON.stringify(data).length > 80 ? '...' : ''));
                safeWrite(res, payload);
            };

            // Handshake (ECHO REQUESTED MODEL)
            sendEvent('response.created', {
                type: 'response.created',
                response: {
                    id: respId,
                    created_at: Math.floor(Date.now() / 1000),
                    model: requestedModel || 'kilo-code-gemini'
                }
            });

            let proxyReq = null;
            res.on('close', () => { if (proxyReq) proxyReq.destroy(); });

            (async () => {
                try {
                    const accessToken = await getAccessToken();
                    const { contents, systemInstructionText, imageLoadError, inlinedImagesInPayload } = await openAiMessagesToGeminiContents(finalMessages);

                    if (imageLoadError) {
                        sendEvent('error', { type: 'error', code: 'image_error', message: imageLoadError, sequence_number: 0 });
                        return safeEnd(res);
                    }

                    if (!contents || contents.length === 0) {
                        sendEvent('error', { type: 'error', code: 'empty_prompt', message: 'No messages provided', sequence_number: 0 });
                        return safeEnd(res);
                    }

                    const body = {
                        contents,
                        generationConfig: {
                            temperature: temperature || 0.7,
                            maxOutputTokens: max_output_tokens || 32768,
                            thinkingConfig: ((inlinedImagesInPayload || !supportsThinkingLevel(MODEL_ID_TO_USE)) ? undefined : { thinkingLevel: "high" })
                        },
                        safetySettings: SAFETY_SETTINGS
                    };

                    if (tools && Array.isArray(tools) && tools.length > 0) {
                        body.tools = [{
                            function_declarations: tools.map(t => ({
                                name: t.function?.name || t.name,
                                description: t.function?.description || t.description || '',
                                parameters: sanitizeSchema(t.function?.parameters || t.parameters || { type: 'object', properties: {} })
                            }))
                        }];
                    }

                    if (systemInstructionText) body.systemInstruction = { role: 'system', parts: [{ text: systemInstructionText }] };

                    const EFFECTIVE_LOCATION = LOCATION_TO_USE;
                    const apiPath = `/v1/projects/${PROJECT_ID}/locations/${EFFECTIVE_LOCATION}/publishers/google/models/${MODEL_ID_TO_USE}:streamGenerateContent?alt=sse`;
                    const postData = JSON.stringify(body);

                    proxyReq = https.request({
                        hostname: 'aiplatform.googleapis.com', port: 443, path: apiPath, method: 'POST',
                        headers: { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) },
                        timeout: 90000
                    }, (proxyRes) => {
                        if (proxyRes.statusCode !== 200) {
                            let errBody = '';
                            proxyRes.on('data', d => errBody += d);
                            proxyRes.on('end', () => {
                                if (proxyRes.statusCode === 401) {
                                    console.log('[AUTH] Token expired during stream (401). Clearing cache for next request.');
                                    cachedAccessToken = null;
                                    cachedTokenExpiresAt = 0;
                                }
                                console.error('[V1/RESP] Gemini Error:', proxyRes.statusCode, errBody);
                                sendEvent('error', { type: 'error', code: 'gemini_error', message: `Gemini Token/API Error (${proxyRes.statusCode}): ${errBody.substring(0, 100)}`, sequence_number: 999 });
                                safeEnd(res);
                            });
                            return;
                        }

                        proxyRes.setEncoding('utf8');
                        let dataBuffer = ''; let fullText = '';
                        let hasStartedText = false;
                        let outputIndexCounter = 0;

                        proxyRes.on('data', chunk => {
                            dataBuffer += chunk;
                            let boundary = dataBuffer.lastIndexOf('\n');
                            if (boundary !== -1) {
                                const rawStr = dataBuffer.substring(0, boundary); dataBuffer = dataBuffer.substring(boundary + 1);
                                rawStr.split('\n').filter(l => l.trim().startsWith('data: ')).forEach(line => {
                                    try {
                                        const parsed = JSON.parse(line.substring(6));
                                        const parts = parsed.candidates?.[0]?.content?.parts || [];
                                        parts.forEach(p => {
                                            if (p.thought) return;

                                            // Capture thinking signatures (support both snake_case from API and camelCase just in case)
                                            const sig = p.thought_signature || p.thoughtSignature || null;
                                            if (p.text) {
                                                if (!hasStartedText) {
                                                    hasStartedText = true;
                                                    sendEvent('response.output_item.added', { type: 'response.output_item.added', output_index: 0, item: { id: msgId, type: 'message' } });
                                                    outputIndexCounter++;
                                                }
                                                fullText += p.text;
                                                sendEvent('response.output_text.delta', { type: 'response.output_text.delta', item_id: msgId, delta: p.text });
                                            }

                                            if (p.functionCall) {
                                                const callId = generateId('call_');
                                                const args = typeof p.functionCall.args === 'string' ? p.functionCall.args : JSON.stringify(p.functionCall.args || {});
                                                const currentIndex = outputIndexCounter++;

                                                toolCallData.set(callId, { name: p.functionCall.name, signature: sig });

                                                sendEvent('response.output_item.added', { type: 'response.output_item.added', output_index: currentIndex, item: { id: callId, type: 'function_call', call_id: callId, name: p.functionCall.name, arguments: '' } });
                                                sendEvent('response.function_call_arguments.delta', { type: 'response.function_call_arguments.delta', item_id: callId, output_index: currentIndex, delta: args });
                                                sendEvent('response.output_item.done', { type: 'response.output_item.done', output_index: currentIndex, item: { id: callId, type: 'function_call', call_id: callId, name: p.functionCall.name, arguments: args, status: 'completed' } });
                                            }
                                        });
                                    } catch (e) { }
                                });
                            }
                        });

                        proxyRes.on('end', () => {
                            if (hasStartedText) {
                                sendEvent('response.output_item.done', { type: 'response.output_item.done', output_index: 0, item: { id: msgId, type: 'message' } });
                            }
                            sendEvent('response.completed', { type: 'response.completed', response: { usage: { input_tokens: 0, output_tokens: 0 } } });
                            safeEnd(res);
                        });

                        proxyRes.on('error', (e) => {
                            sendEvent('error', { type: 'error', code: 'stream_error', message: e.message, sequence_number: 999 });
                            safeEnd(res);
                        });
                    });

                    proxyReq.on('error', (e) => {
                        sendEvent('error', { type: 'error', code: 'req_error', message: e.message, sequence_number: 999 });
                        safeEnd(res);
                    });

                    proxyReq.write(postData); proxyReq.end();
                } catch (err) {
                    sendEvent('error', { type: 'error', code: 'internal_error', message: err.message, sequence_number: 999 });
                    safeEnd(res);
                }
            })();
        } else {
            const accessToken = await getAccessToken();
            const { contents, systemInstructionText, imageLoadError, inlinedImagesInPayload } = await openAiMessagesToGeminiContents(finalMessages);
            if (imageLoadError) return res.status(400).json({ error: imageLoadError });
            const body = {
                contents,
                generationConfig: {
                    temperature: temperature || 0.7,
                    maxOutputTokens: max_output_tokens || 32768,
                    thinkingConfig: ((inlinedImagesInPayload || !supportsThinkingLevel(MODEL_ID_TO_USE)) ? undefined : { thinkingLevel: "high" })
                },
                safetySettings: SAFETY_SETTINGS
            };
            if (systemInstructionText) body.systemInstruction = { role: 'system', parts: [{ text: systemInstructionText }] };

            if (tools && Array.isArray(tools) && tools.length > 0) {
                body.tools = [{
                    function_declarations: tools.map(t => ({
                        name: t.function?.name || t.name,
                        description: t.function?.description || t.description || '',
                        parameters: sanitizeSchema(t.function?.parameters || t.parameters || { type: 'object', properties: {} })
                    }))
                }];
            }
            const rawResponseObj = await callGeminiAPIWithRetry(baseRequestBody, false, MODEL_ID_TO_USE, LOCATION_TO_USE);

            if (rawResponseObj.statusCode !== 200) {
                 return res.status(rawResponseObj.statusCode).json({
                    error: {
                        message: `Gemini API Error: ${JSON.stringify(rawResponseObj.data)}`,
                        type: 'api_error',
                        param: null,
                        code: rawResponseObj.statusCode
                    }
                });
            }

            const rawResponse = rawResponseObj.data;
            let reply = ''; const outputItems = [];
            const resultChunks = Array.isArray(rawResponse) ? rawResponse : [rawResponse];
            resultChunks.forEach(chunk => {
                const pList = chunk.candidates?.[0]?.content?.parts || [];
                pList.forEach(p => {
                    if (p.text) reply += p.text;
                    if (p.functionCall) {
                        const callId = generateId('call_');
                        const funcArgs = JSON.stringify(p.functionCall.args || {});

                        // UNIVERSAL MEMORY: Store the ID with thinking signature
                        toolCallData.set(callId, {
                            name: p.functionCall.name,
                            signature: p.thought_signature || p.thoughtSignature || null
                        });

                        outputItems.push({
                            id: generateId('fc_'),
                            type: 'function_call',
                            call_id: callId,
                            name: p.functionCall.name,
                            arguments: funcArgs,
                            status: 'completed'
                        });
                    }
                });
            });
            if (reply) outputItems.unshift({ id: msgId, type: 'message', role: 'assistant', status: 'completed', content: [{ type: 'output_text', text: reply }] });
            res.json({
                id: respId,
                model: requestedModel || 'kilo-code-gemini',
                output: outputItems,
                usage: { input_tokens: 0, output_tokens: 0 }
            });
        }
    } catch (err) { res.status(500).json({ error: err.message }); }
});

// ============================================================================
// VERTEX MODEL CATALOG + IMAGE GENERATION
// ============================================================================

function vertexHost(location) {
    return (!location || location === 'global') ? 'aiplatform.googleapis.com' : `${location}-aiplatform.googleapis.com`;
}

// Generic authenticated JSON request to Vertex AI, with one 401 refresh retry.
async function vertexJson(method, hostname, apiPath, body, forceRefresh = false) {
    const accessToken = await getAccessToken(forceRefresh);
    const postData = body ? JSON.stringify(body) : null;
    const result = await new Promise((resolve, reject) => {
        const headers = {
            'Authorization': `Bearer ${accessToken}`,
            'x-goog-user-project': PROJECT_ID
        };
        if (postData) {
            headers['Content-Type'] = 'application/json';
            headers['Content-Length'] = Buffer.byteLength(postData);
        }
        const r = https.request({ hostname, port: 443, path: apiPath, method, headers, timeout: 120000 }, (resp) => {
            const chunks = [];
            resp.on('data', c => chunks.push(c));
            resp.on('end', () => {
                const text = Buffer.concat(chunks).toString('utf8');
                let data = null;
                try { data = JSON.parse(text); } catch (_) { data = { raw: text.substring(0, 500) }; }
                resolve({ statusCode: resp.statusCode, data });
            });
        });
        r.on('timeout', () => r.destroy(new Error('Vertex request timed out')));
        r.on('error', reject);
        if (postData) r.write(postData);
        r.end();
    });
    if (result.statusCode === 401 && !forceRefresh) {
        cachedAccessToken = null;
        return vertexJson(method, hostname, apiPath, body, true);
    }
    return result;
}

// Classify a Vertex model id into a capability bucket.
function classifyModel(id) {
    const s = String(id || '').toLowerCase();
    if (s.startsWith('automl')) return 'other';
    if (s.startsWith('imagen') || /-image(-|$)/.test(s) || s.includes('nano-banana')) return 'image';
    if (s.startsWith('veo')) return 'video';
    if (s.includes('embedding')) return 'embedding';
    if (s.includes('tts') || s.startsWith('chirp') || s.includes('lyria') || s.includes('native-audio')) return 'audio';
    if (s.startsWith('gemini') || s.startsWith('gemma') || s.startsWith('gpt-')) return 'chat';
    return 'other';
}

function supportsThinkingLevel(id) { return /gemini-3/i.test(String(id || '')); }
function isImagenModel(id) { return /^imagen/i.test(id); }
function isImageModel(id) { return classifyModel(id) === 'image'; }

const FALLBACK_MODELS = [
    'gemini-3.1-pro-preview', 'gemini-3-flash-preview', 'gemini-2.5-pro', 'gemini-2.5-flash', 'gemini-2.5-flash-lite',
    'gemini-3-pro-image-preview', 'gemini-2.5-flash-image',
    'imagen-4.0-generate-001', 'imagen-4.0-fast-generate-001', 'imagen-4.0-ultra-generate-001', 'imagen-3.0-generate-002',
    'text-embedding-005', 'gemini-embedding-001'
];

let modelCatalogCache = { at: 0, ids: null };
const MODEL_CATALOG_TTL = 60 * 60 * 1000;

// Lists every Google publisher model Vertex AI exposes (Model Garden API).
async function listVertexModels() {
    if (modelCatalogCache.ids && Date.now() - modelCatalogCache.at < MODEL_CATALOG_TTL) {
        return modelCatalogCache.ids;
    }
    const ids = new Set();
    let pageToken = '';
    try {
        for (let page = 0; page < 20; page++) {
            const qs = `pageSize=200${pageToken ? `&pageToken=${encodeURIComponent(pageToken)}` : ''}`;
            const { statusCode, data } = await vertexJson('GET', 'us-central1-aiplatform.googleapis.com', `/v1beta1/publishers/google/models?${qs}`);
            if (statusCode !== 200) throw new Error(`HTTP ${statusCode}: ${JSON.stringify(data).substring(0, 300)}`);
            for (const m of (data.publisherModels || [])) {
                const id = String(m.name || '').split('/').pop();
                // Only models callable directly over the API (serverless). Models with
                // an openSourceCategory (gemma2, bert, alphafold3, ...) must first be
                // deployed to an endpoint, so they are not usable through this proxy.
                // Partner/open models served as MaaS end in "-maas".
                if (!id) continue;
                if (m.openSourceCategory && !/-maas$/i.test(id)) continue;
                ids.add(id);
            }
            pageToken = data.nextPageToken;
            if (!pageToken) break;
        }
    } catch (e) {
        console.log(`[MODELS] Live model list failed, using fallback list: ${e.message}`);
    }
    // The fallback list is used only when the live catalog is unavailable; merging
    // it in would list models the project cannot actually call.
    const list = ids.size ? [...ids].sort() : FALLBACK_MODELS.slice();
    if (ids.size) modelCatalogCache = { at: Date.now(), ids: list };
    return list;
}

// OpenAI "size" (e.g. 1024x1792) -> nearest Vertex aspect ratio.
const IMAGE_ASPECT_RATIOS = { '1:1': 1, '2:3': 2 / 3, '3:2': 1.5, '3:4': 3 / 4, '4:3': 4 / 3, '4:5': 0.8, '5:4': 1.25, '9:16': 9 / 16, '16:9': 16 / 9, '21:9': 21 / 9 };
function sizeToAspectRatio(size, explicit) {
    if (explicit && IMAGE_ASPECT_RATIOS[explicit]) return explicit;
    const m = /^(\d+)x(\d+)$/.exec(String(size || ''));
    if (!m) return '1:1';
    const r = Number(m[1]) / Number(m[2]);
    const options = IMAGE_ASPECT_RATIOS;
    return Object.entries(options).sort((a, b) => Math.abs(a[1] - r) - Math.abs(b[1] - r))[0][0];
}

// Generates images with either an Imagen model (:predict) or a Gemini image
// model (:generateContent with IMAGE output). Returns { images: [{ b64, mimeType }], text }.
const imageSignatureCache = new LRUCache(500); // sha1(image b64) -> thoughtSignature
function imageKey(b64) { return require('crypto').createHash('sha1').update(b64).digest('hex'); }

// Optional client options for Gemini image models (Vertex AI Studio app). `vertex` =
// { location, generationConfig: { responseModalities, maxOutputTokens, thinkingConfig, mediaResolution,
//   imageConfig: { aspectRatio, imageSize, imageOutputOptions, personGeneration } }, tools: [{ googleSearch }] }.
// A field Vertex rejects for a model is dropped (reported back as `dropped`) instead of failing the request.
const OPTIONAL_IMAGE_FIELDS = [
    ['tools'],
    ['generationConfig', 'mediaResolution'],
    ['generationConfig', 'thinkingConfig'],
    ['generationConfig', 'imageConfig', 'imageOutputOptions'],
    ['generationConfig', 'imageConfig', 'personGeneration'],
    ['generationConfig', 'imageConfig', 'imageSize'],
    ['generationConfig', 'maxOutputTokens'],
];
function hasPath(o, path) { return path.reduce((a, k) => (a == null ? a : a[k]), o) !== undefined; }
function deletePath(o, path) {
    const parent = path.slice(0, -1).reduce((a, k) => (a == null ? a : a[k]), o);
    if (parent) delete parent[path[path.length - 1]];
}
// The optional field a 400 error complains about, or null when the error is not about options.
function rejectedImageField(body, message) {
    const msg = String(message || '');
    for (const path of OPTIONAL_IMAGE_FIELDS) {
        if (!hasPath(body, path)) continue;
        const name = path[path.length - 1];
        const snake = name.replace(/[A-Z]/g, c => '_' + c.toLowerCase());
        if (msg.includes(name) || msg.includes(snake)) return path;
    }
    const guesses = [
        [/search|grounding|tool/i, ['tools']],
        [/thinking/i, ['generationConfig', 'thinkingConfig']],
        [/media.?resolution/i, ['generationConfig', 'mediaResolution']],
        [/image.?size|resolution/i, ['generationConfig', 'imageConfig', 'imageSize']],
        [/mime|output.?format|output.?options/i, ['generationConfig', 'imageConfig', 'imageOutputOptions']],
        [/person/i, ['generationConfig', 'imageConfig', 'personGeneration']],
    ];
    for (const [re, path] of guesses) if (re.test(msg) && hasPath(body, path)) return path;
    return null;
}

function buildImageGenerationConfig(model, ar, vertex) {
    const vgc = (vertex && vertex.generationConfig) || {};
    const gc = { responseModalities: ['TEXT', 'IMAGE'] };
    if (Array.isArray(vgc.responseModalities) && vgc.responseModalities.includes('IMAGE')) gc.responseModalities = vgc.responseModalities;
    if (Number(vgc.maxOutputTokens) > 0) gc.maxOutputTokens = Number(vgc.maxOutputTokens);
    if (vgc.mediaResolution) gc.mediaResolution = vgc.mediaResolution;
    // thinkingLevel is Gemini 3+ only; older models reject it.
    if (vgc.thinkingConfig && supportsThinkingLevel(model)) gc.thinkingConfig = vgc.thinkingConfig;
    const vic = vgc.imageConfig || {};
    gc.imageConfig = { aspectRatio: IMAGE_ASPECT_RATIOS[vic.aspectRatio] ? vic.aspectRatio : ar };
    if (['1K', '2K', '4K'].includes(vic.imageSize)) gc.imageConfig.imageSize = vic.imageSize;
    if (vic.imageOutputOptions && vic.imageOutputOptions.mimeType) gc.imageConfig.imageOutputOptions = vic.imageOutputOptions;
    if (vic.personGeneration) gc.imageConfig.personGeneration = vic.personGeneration;
    return gc;
}

async function generateImages({ model, prompt, n = 1, size, aspectRatio, inputImages = [], extra = {}, contents = null, systemInstruction = null, vertex = null }) {
    const ar = sizeToAspectRatio(size, aspectRatio);
    const count = Math.max(1, Math.min(4, Number(n) || 1));
    if (isImagenModel(model)) {
        const loc = LOCATION === 'global' ? 'us-central1' : LOCATION;
        const parameters = { sampleCount: count, aspectRatio: ar, ...extra };
        const { statusCode, data } = await vertexJson('POST', vertexHost(loc),
            `/v1/projects/${PROJECT_ID}/locations/${loc}/publishers/google/models/${model}:predict`,
            { instances: [{ prompt }], parameters });
        if (statusCode !== 200) throw Object.assign(new Error(data?.error?.message || `Imagen HTTP ${statusCode}`), { statusCode });
        const images = (data.predictions || []).filter(p => p.bytesBase64Encoded)
            .map(p => ({ b64: p.bytesBase64Encoded, mimeType: p.mimeType || 'image/png' }));
        if (!images.length) throw Object.assign(new Error('Imagen returned no images (likely blocked by safety filters).'), { statusCode: 400 });
        return { images, text: '' };
    }

    // Gemini native image model (also supports editing via input images).
    // `contents` (full multi-turn history) overrides prompt/inputImages.
    const body = {
        contents: contents || [{ role: 'user', parts: [...inputImages, { text: prompt }] }],
        generationConfig: buildImageGenerationConfig(model, ar, vertex),
        safetySettings: SAFETY_SETTINGS
    };
    // Only Google Search grounding is a real Vertex tool here; anything else is ignored.
    const tools = ((vertex && vertex.tools) || []).filter(t => t && t.googleSearch);
    if (tools.length) body.tools = tools.map(t => ({ googleSearch: t.googleSearch || {} }));
    if (systemInstruction) body.systemInstruction = { role: 'system', parts: [{ text: systemInstruction }] };
    const location = (vertex && typeof vertex.location === 'string' && /^[a-z0-9-]+$/.test(vertex.location)) ? vertex.location : LOCATION;
    const dropped = [];
    if (vertex && vertex.celebrityGeneration) dropped.push('celebrityGeneration (no Vertex field)');
    if (vertex && (vertex.tools || []).some(t => t && !t.googleSearch)) dropped.push('tools other than googleSearch');
    const images = [];
    let text = '';
    let thoughts = '';
    for (let i = 0; i < count; i++) {
        // Image generation on Vertex occasionally stalls or returns 429/5xx: retry once.
        let statusCode, data;
        for (let attempt = 0, failures = 0; attempt < 9; attempt++) {
            try {
                ({ statusCode, data } = await vertexJson('POST', vertexHost(location),
                    `/v1/projects/${PROJECT_ID}/locations/${location}/publishers/google/models/${model}:generateContent`, body));
            } catch (e) {
                if (failures++ === 0) { console.log(`[IMAGES] ${e.message}, retrying once`); continue; }
                throw e;
            }
            if (statusCode === 400) {
                // An optional client option this model does not accept: drop it and retry.
                const path = rejectedImageField(body, data?.error?.message);
                if (path) {
                    deletePath(body, path);
                    dropped.push(path.join('.'));
                    console.log(`[IMAGES] Vertex rejected ${path.join('.')} for ${model}: ${String(data?.error?.message || '').slice(0, 200)}`);
                    continue;
                }
            }
            // 429 "Resource exhausted" on global preview image models is usually a
            // short shared-capacity spike (the same request succeeds moments later),
            // so back off a few times; 5xx gets one quick retry.
            const backoff = statusCode === 429 ? [5000, 15000, 30000] : statusCode >= 500 ? [3000] : [];
            if (failures < backoff.length) {
                const wait = backoff[failures++];
                console.log(`[IMAGES] HTTP ${statusCode}: ${String(data?.error?.message || '').slice(0, 160)} - retry ${failures}/${backoff.length} in ${wait / 1000}s`);
                await new Promise(r => setTimeout(r, wait));
                continue;
            }
            break;
        }
        if (statusCode !== 200) throw Object.assign(new Error(data?.error?.message || `Gemini image HTTP ${statusCode}`), { statusCode });
        for (const p of (data.candidates?.[0]?.content?.parts || [])) {
            // With includeThoughts the model can also return draft images from its
            // thinking (thought: true); only the final images are results.
            if (p.inlineData?.data && p.thought) continue;
            if (p.inlineData?.data) {
                images.push({ b64: p.inlineData.data, mimeType: p.inlineData.mimeType || 'image/png' });
                // Gemini 3 image models need this signature back when the image is
                // replayed in a later turn; the client only keeps the image itself.
                const sig = p.thoughtSignature || p.thought_signature;
                if (sig) imageSignatureCache.set(imageKey(p.inlineData.data), sig);
            }
            else if (p.text && p.thought) thoughts += p.text;
            else if (p.text) text += p.text;
        }
    }
    if (dropped.length) console.log(`[IMAGES] Options not applied for ${model}: ${dropped.join(', ')}`);
    if (!images.length) throw Object.assign(new Error(text || 'Model returned no image.'), { statusCode: 400 });
    return { images, text, thoughts, dropped };
}

function sendOpenAIError(res, e) {
    const code = e.statusCode && e.statusCode >= 400 && e.statusCode < 600 ? e.statusCode : 500;
    res.status(code).json({ error: { message: e.message, type: code < 500 ? 'invalid_request_error' : 'api_error', param: null, code: null } });
}

// OpenAI-compatible image generation: POST /v1/images/generations
// Optional input images for editing (Gemini image models): body.image / body.images
// as data: URIs, http(s) URLs or raw base64.
app.post('/v1/images/generations', async (req, res) => {
    try {
        const { prompt, n, size, response_format, aspect_ratio } = req.body || {};
        const model = resolveVertexModel(req.body?.model || process.env.IMAGE_MODEL_ID || 'imagen-4.0-generate-001');
        if (!prompt) return res.status(400).json({ error: { message: 'prompt is required', type: 'invalid_request_error' } });
        const rawImages = [].concat(req.body.images || [], req.body.image || []);
        const inputImages = [];
        for (const u of rawImages) {
            const part = await resolveOpenAIImageUrl(typeof u === 'string' ? u : (u?.url || u?.image_url));
            if (part) inputImages.push(part);
        }
        console.log(`[IMAGES] model=${model} n=${n || 1} size=${size || '-'} inputImages=${inputImages.length}`);
        const { images, text } = await generateImages({ model, prompt, n, size, aspectRatio: aspect_ratio, inputImages, extra: req.body.parameters || {}, vertex: req.body.vertex || null });
        res.json({
            created: Math.floor(Date.now() / 1000),
            data: images.map(img => response_format === 'url'
                ? { url: `data:${img.mimeType};base64,${img.b64}`, revised_prompt: text || undefined }
                : { b64_json: img.b64, revised_prompt: text || undefined })
        });
    } catch (e) {
        console.error('[IMAGES] Error:', e.message);
        sendOpenAIError(res, e);
    }
});

// Image model used through /v1/chat/completions: the last user message is the
// prompt, attached images are edit inputs, and the result comes back as markdown
// image(s) with data: URIs (renders in Open WebUI etc.).
async function handleImageModelChat(req, res, model) {
    try {
        const { messages, stream } = req.body;
        const lastUser = [...messages].reverse().find(m => m.role === 'user') || {};
        let prompt = '';
        const inputImages = [];
        if (typeof lastUser.content === 'string') prompt = lastUser.content;
        else for (const c of (lastUser.content || [])) {
            if (c.type === 'text') prompt += (prompt ? '\n' : '') + c.text;
            else if (c.type === 'image_url' && !isImagenModel(model)) {
                const part = await resolveOpenAIImageUrl(c.image_url?.url || c.image_url);
                if (part) inputImages.push(part);
            }
        }
        // Gemini image models get the whole conversation, so "make it bluer" edits
        // the previous result. Imagen is single-shot: last user prompt only.
        let contents = null;
        let systemInstruction = null;
        if (!isImagenModel(model)) {
            contents = [];
            const sys = [];
            for (const m of messages) {
                const parts = [];
                const items = typeof m.content === 'string' ? [{ type: 'text', text: m.content }] : (m.content || []);
                if (m.role === 'system' || m.role === 'developer') {
                    sys.push(items.filter(c => c.type === 'text').map(c => c.text).join('\n'));
                    continue;
                }
                for (const c of items) {
                    if (c.type === 'image_url') {
                        const part = await resolveOpenAIImageUrl(c.image_url?.url || c.image_url);
                        if (part) parts.push(part);
                    } else if (c.type === 'text' && c.text) {
                        // Previous assistant replies carry images as markdown data: URIs.
                        const re = /!\[[^\]]*\]\((data:([^;]+);base64,([A-Za-z0-9+/=]+))\)/g;
                        let last = 0, mm;
                        while ((mm = re.exec(c.text))) {
                            const before = c.text.slice(last, mm.index).trim();
                            if (before) parts.push({ text: before });
                            const imgPart = { inlineData: { mimeType: normalizeGeminiImageMime(mm[2]), data: mm[3] } };
                            if (m.role === 'assistant') {
                                imgPart.thoughtSignature = imageSignatureCache.get(imageKey(mm[3])) || SKIP_THOUGHT_SIGNATURE_VALIDATOR;
                            }
                            parts.push(imgPart);
                            last = re.lastIndex;
                        }
                        const rest = c.text.slice(last).trim();
                        if (rest) parts.push({ text: rest });
                    }
                }
                if (parts.length) contents.push({ role: m.role === 'assistant' ? 'model' : 'user', parts });
            }
            systemInstruction = sys.filter(Boolean).join('\n') || null;
            console.log(`[V1/CHAT image] ${contents.length} turns, ${contents.reduce((a, c) => a + c.parts.filter(p => p.inlineData).length, 0)} images in history`);
        }
        const { images, text, thoughts, dropped } = await generateImages({ model, prompt, n: req.body.n || 1, size: req.body.size, aspectRatio: req.body.aspect_ratio, inputImages, contents, systemInstruction, vertex: req.body.vertex || null });
        const content = [text, ...images.map((img, i) => `![image ${i + 1}](data:${img.mimeType};base64,${img.b64})`)].filter(Boolean).join('\n\n');
        const id = `chatcmpl-${Date.now()}`;
        const created = Math.floor(Date.now() / 1000);
        if (stream === true) {
            res.setHeader('Content-Type', 'text/event-stream');
            res.setHeader('Cache-Control', 'no-cache');
            res.write(`data: ${JSON.stringify({ id, object: 'chat.completion.chunk', created, model, choices: [{ index: 0, delta: { role: 'assistant', content, ...(thoughts ? { reasoning_content: thoughts } : {}) }, finish_reason: null }], ...(dropped.length ? { vertex_dropped: dropped } : {}) })}\n\n`);
            res.write(`data: ${JSON.stringify({ id, object: 'chat.completion.chunk', created, model, choices: [{ index: 0, delta: {}, finish_reason: 'stop' }] })}\n\n`);
            return res.end('data: [DONE]\n\n');
        }
        res.json({ id, object: 'chat.completion', created, model, choices: [{ index: 0, message: { role: 'assistant', content, ...(thoughts ? { reasoning_content: thoughts } : {}) }, finish_reason: 'stop' }], usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 }, ...(dropped.length ? { vertex_dropped: dropped } : {}) });
    } catch (e) {
        console.error('[V1/CHAT image] Error:', e.message);
        sendOpenAIError(res, e);
    }
}

// ============================================================================
// OPENAI-COMPATIBLE ENDPOINT: /v1/models  (live Vertex catalog, all modalities)
// ?type=chat|image|video|embedding|audio filters; ?refresh=1 bypasses the cache.
// ============================================================================

app.get('/v1/models', async (req, res) => {
    if (req.query.refresh) modelCatalogCache = { at: 0, ids: null };
    const ids = await listVertexModels();
    const all = [MODEL_ID, ...ids, 'gpt-4o', 'gpt-4o-mini'].filter((m, i, arr) => m && arr.indexOf(m) === i);
    const wanted = req.query.type ? String(req.query.type).split(',') : null;
    const data = all.map(id => {
        const type = classifyModel(resolveVertexModel(id));
        return {
            id, object: 'model', created: 1715385600, owned_by: 'google', permission: [], root: id, parent: null,
            type,
            input_modalities: (type === 'chat' || type === 'image') ? ['text', 'image'] : ['text'],
            output_modalities: type === 'image' ? ['image', 'text'] : type === 'video' ? ['video'] : type === 'audio' ? ['audio'] : ['text'],
            capabilities: {
                vision: type === 'chat' || (type === 'image' && !isImagenModel(id)),
                reasoning: type === 'chat' && /gemini-(2\.5|3)/i.test(id),
                tool_use: type === 'chat',
                json_mode: type === 'chat',
                image_generation: type === 'image'
            }
        };
    // "other" (OCR, detectors, ...) can't be called via chat/images; list them only when asked.
    }).filter(m => wanted ? wanted.includes(m.type) : m.type !== 'other');
    res.json({ object: 'list', data });
});

// ============================================================================
// ROOT ENDPOINT
// ============================================================================

app.get('/', (req, res) => {
    res.json({
        name: 'Vertex AI Gemini Server',
        version: '1.0.0',
        endpoints: {
            health: 'GET /health',
            chat: 'POST /chat',
            chatCompletions: 'POST /v1/chat/completions (OpenAI-compatible)'
        },
        currentConfig: {
            model: MODEL_ID,
            location: LOCATION,
            projectId: PROJECT_ID
        },
        usage: {
            legacyEndpoint: {
                method: 'POST',
                url: 'http://localhost:3000/chat',
                body: { prompt: 'Your question' }
            },
            openaiCompatible: {
                method: 'POST',
                url: 'http://localhost:3000/v1/chat/completions',
                body: {
                    model: 'gemini-3.1-pro-preview',
                    messages: [
                        { role: 'system', content: 'You are helpful.' },
                        { role: 'user', content: 'Hello!' }
                    ],
                    stream: false
                }
            }
        }
    });
});

// ============================================================================
// SERVER STARTUP
// ============================================================================

app.listen(PORT, () => {
    // Warm the model catalog so the first /v1/models call (e.g. the GUI dropdown) is instant.
    listVertexModels().then(l => console.log(`[MODELS] ${l.length} models available`)).catch(() => {});
    console.log('='.repeat(60));
    console.log('  Vertex AI Gemini Backend Server');
    console.log('='.repeat(60));
    console.log(`  Server running at: http://localhost:${PORT}`);
    console.log(`  Health check:      GET  http://localhost:${PORT}/health`);
    console.log(`  Legacy chat:       POST http://localhost:${PORT}/chat`);
    console.log(`  OpenAI compat:     POST http://localhost:${PORT}/v1/chat/completions`);
    console.log('='.repeat(60));
    console.log('');
    console.log('  Configuration:');
    console.log(`    Project ID:   ${PROJECT_ID || 'NOT SET'}`);
    console.log(`    Location:     ${LOCATION}`);
    console.log(`    Model:        ${MODEL_ID}`);
    console.log('');

    const credPath = getCredentialsPath();
    if (credPath) {
        console.log(`    ADC Credentials: ${credPath}`);
        console.log('  [OK] Google Application Default Credentials configured!');
    } else {
        console.log('  [WARN] No Google ADC file detected. Run: gcloud auth application-default login');
    }
    console.log('  [TIP] If using node --watch, logs are in ./debug_logs/ to prevent reboot loops.');
    console.log('');
});

module.exports = app;
