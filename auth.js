/**
 * OAuth Authentication Script for Vertex AI
 * 
 * This script authenticates you with Google Cloud using OAuth2
 * so you can use Vertex AI without a service account key file.
 * 
 * Run: node auth.js
 */

require('dotenv').config();
const http = require('http');
const url = require('url');
const fs = require('fs');
const path = require('path');

// Your OAuth client credentials (from Google Cloud Console)
const CLIENT_ID = process.env.GOOGLE_CLIENT_ID || 'your-client-id.apps.googleusercontent.com';
const CLIENT_SECRET = process.env.GOOGLE_CLIENT_SECRET || 'your-client-secret';

// Redirect URI for local desktop app
const REDIRECT_URI = 'http://localhost:3001/oauth/callback';

// Port for the local server
const PORT = 3001;

// Scopes needed for Vertex AI
const SCOPES = [
    'https://www.googleapis.com/auth/cloud-platform'
];

// Generate the OAuth consent URL
function getAuthUrl() {
    const params = new url.URLSearchParams({
        client_id: CLIENT_ID,
        redirect_uri: REDIRECT_URI,
        response_type: 'code',
        scope: SCOPES.join(' '),
        access_type: 'offline',
        prompt: 'consent'
    });
    
    return `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`;
}

// Exchange authorization code for tokens
async function exchangeCodeForTokens(code) {
    const response = await fetch('https://oauth2.googleapis.com/token', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/x-www-form-urlencoded'
        },
        body: new url.URLSearchParams({
            client_id: CLIENT_ID,
            client_secret: CLIENT_SECRET,
            code: code,
            grant_type: 'authorization_code',
            redirect_uri: REDIRECT_URI
        })
    });
    
    return response.json();
}

// Save credentials to ADC file
function saveAdcCredentials(tokens) {
    const adcPath = path.join(process.env.APPDATA || process.env.HOME, 'google-applications', 'application_default_credentials.json');
    
    // Ensure directory exists
    const dir = path.dirname(adcPath);
    if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
    }
    
    const credentials = {
        client_id: CLIENT_ID,
        client_secret: CLIENT_SECRET,
        refresh_token: tokens.refresh_token,
        type: 'authorized_user'
    };
    
    fs.writeFileSync(adcPath, JSON.stringify(credentials, null, 2));
    console.log(`\n✅ Credentials saved to: ${adcPath}`);
}

// Start local server to receive OAuth callback
function startServer() {
    return new Promise((resolve) => {
        const server = http.createServer((req, res) => {
            const parsedUrl = url.parse(req.url, true);
            
            if (parsedUrl.pathname === '/oauth/callback') {
                const code = parsedUrl.query.code;
                
                if (code) {
                    res.writeHead(200, { 'Content-Type': 'text/html' });
                    res.end(`
                        <html>
                            <body style="font-family: Arial; text-align: center; padding: 50px;">
                                <h2 style="color: green;">✅ Authentication Successful!</h2>
                                <p>You can close this window and return to the terminal.</p>
                                <script>window.close();</script>
                            </body>
                        </html>
                    `);
                    
                    server.close();
                    resolve(code);
                } else {
                    res.writeHead(400, { 'Content-Type': 'text/html' });
                    res.end('<html><body><h2>Error: No authorization code received</h2></body></html>');
                }
            } else {
                res.writeHead(404, { 'Content-Type': 'text/plain' });
                res.end('Not Found');
            }
        });
        
        server.listen(PORT, () => {
            console.log(`\n📌 Local server running on port ${PORT}`);
        });
    });
}

// Main function
async function main() {
    console.log('='.repeat(60));
    console.log('  Google Cloud OAuth Authentication');
    console.log('='.repeat(60));
    console.log('\n📋 Steps:');
    console.log('1. This script will open your browser for authentication');
    console.log('2. You will authorize access to your Google account');
    console.log('3. The authorization code will be captured automatically');
    console.log('\n🔐 Opening browser for authentication...\n');
    
    // Open browser
    const authUrl = getAuthUrl();
    console.log(`📎 Auth URL: ${authUrl}\n`);
    
    // Try to open browser automatically
    try {
        const { exec } = require('child_process');
        if (process.platform === 'win32') {
            exec(`start "${authUrl}"`, (err) => {
                if (err) console.log('Please manually open the URL in your browser.');
            });
        } else if (process.platform === 'darwin') {
            exec(`open "${authUrl}"`, (err) => {
                if (err) console.log('Please manually open the URL in your browser.');
            });
        } else {
            console.log('Please manually open this URL in your browser:');
            console.log(authUrl);
        }
    } catch (e) {
        console.log('Please manually open the URL in your browser:');
        console.log(authUrl);
    }
    
    // Wait for user to authorize
    console.log('⏳ Waiting for authorization...');
    console.log('   (If browser did not open, copy the URL above and paste into your browser)\n');
    
    const code = await startServer();
    console.log('🔄 Exchanging authorization code for tokens...');
    
    try {
        const tokens = await exchangeCodeForTokens(code);
        
        if (tokens.error) {
            console.error(`\n❌ Error: ${tokens.error}`);
            console.error(`   ${tokens.error_description}`);
            process.exit(1);
        }
        
        console.log('✅ Successfully obtained tokens!');
        saveAdcCredentials(tokens);
        
        console.log('\n' + '='.repeat(60));
        console.log('  ✅ Authentication Complete!');
        console.log('='.repeat(60));
        console.log('\n📝 Next steps:');
        console.log('1. Grant yourself Vertex AI access (see below)');
        console.log('2. Run: node index.js');
        console.log('\n🔑 To grant Vertex AI access, run this command in Cloud Shell:');
        console.log('   gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \\');
        console.log('     --member="user:YOUR_EMAIL@gmail.com" \\');
        console.log('     --role="roles/aiplatform.user"');
        console.log('\n   Important: Replace YOUR_PROJECT_ID with your actual Google Cloud Project ID.');
        console.log('   Replace YOUR_EMAIL@gmail.com with your actual Google email.\n');
        
    } catch (error) {
        console.error(`\n❌ Failed to exchange code for tokens: ${error.message}`);
        process.exit(1);
    }
}

main();