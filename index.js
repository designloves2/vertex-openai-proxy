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
            let data = '';
            proxyRes.on('data', chunk => data += chunk);
            proxyRes.on('end', () => {
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
            let data = '';
            proxyRes.on('data', chunk => data += chunk);
            proxyRes.on('end', () => {
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
                let data = '';
                proxyRes.on('data', chunk => data += chunk);
                proxyRes.on('end', () => {
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
                    const funcArgs = typeof tc.function.arguments === 'string' ? JSON.parse(tc.function.arguments || '{}') : tc.function.arguments;
                    // RESTORE: Look up the signature from our internal toolCallData Map
                    const stored = toolCallData.get(tc.id) || {};
                    const fallbackSignature =
                        stored.signature ||
                        toolSignatureByName.get(funcName) ||
                        null;

                    const callPart = { functionCall: { name: funcName, args: funcArgs } };

                    // Gemini 3 requires the signature on the original functionCall part.
                    if (fallbackSignature) {
                        callPart.thought_signature = fallbackSignature;
                    } else {
                        console.warn(`[V1/CHAT] Missing thought signature for tool call: ${funcName} (${tc.id})`);
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
                if (typeof parsedResponse !== 'object' || parsedResponse === null) parsedResponse = { result: parsedResponse };
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

        if (!inlinedImagesInPayload && isGemini3Flash) {
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
            const accessToken = await getAccessToken();
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
                    proxyRes.on('end', () => {
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
                            thinkingConfig: (inlinedImagesInPayload ? undefined : { thinkingLevel: "high" })
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
                    thinkingConfig: (inlinedImagesInPayload ? undefined : { thinkingLevel: "high" })
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
// OPENAI-COMPATIBLE ENDPOINT: /v1/models
// ============================================================================

app.get('/v1/models', (req, res) => {
    const list = [
        { id: MODEL_ID, vision: true, reasoning: /gemini-3/i.test(MODEL_ID) },
        { id: "gpt-4o", vision: true, reasoning: true },
        { id: "gpt-4o-mini", vision: true, reasoning: false },
        { id: "Gemini 3.1 Pro (Vision)", vision: true, reasoning: true },
        { id: "gemini-3.8-flash", vision: true, reasoning: true },
        { id: "gemini-1.5-pro-002", vision: true, reasoning: true },
        { id: "gemini-1.5-flash-002", vision: true, reasoning: false }
    ].filter((m, i, arr) => arr.findIndex(x => x.id === m.id) === i);

    res.json({
        object: "list",
        data: list.map(m => ({
            id: m.id,
            object: "model",
            created: 1715385600,
            owned_by: "system",
            permission: [],
            root: m.id,
            parent: null,
            input_modalities: ["text", "image"],
            capabilities: {
                vision: m.vision,
                reasoning: m.reasoning,
                tool_use: true,
                json_mode: true
            }
        }))
    });
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
    console.log('  ?뮕 TIP: If using node --watch, logs are in ./debug_logs/ to prevent reboot loops.');
    console.log('');
});

module.exports = app;
