<#
.SYNOPSIS
    One-shot installer for vertex-openai-proxy on Windows.
.DESCRIPTION
    Installs prerequisites (Node.js, Google Cloud CLI), authenticates with
    Google Cloud (Application Default Credentials), writes .env, installs
    npm dependencies, and optionally starts the server.
.NOTES
    Run from PowerShell (right-click PowerShell -> "Run as Administrator" recommended
    for the first run so winget can install packages):
        powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
#>

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-Command($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

# ---------------------------------------------------------------------------
# 1. winget 확인
# ---------------------------------------------------------------------------
Step "1/7 winget 확인"
if (-not (Test-Command "winget")) {
    Err "winget이 없습니다. Microsoft Store에서 'App Installer'를 설치한 뒤 다시 실행해주세요."
    exit 1
}
Write-Host "winget 확인됨"

# ---------------------------------------------------------------------------
# 2. Node.js
# ---------------------------------------------------------------------------
Step "2/7 Node.js 확인"
if (-not (Test-Command "node")) {
    Write-Host "Node.js가 설치되어 있지 않습니다. 설치를 진행합니다..."
    winget install --id OpenJS.NodeJS.LTS -e --source winget --accept-package-agreements --accept-source-agreements
    Write-Host "설치가 끝났습니다. 이 창을 닫고 새 PowerShell 창에서 스크립트를 다시 실행해주세요." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "Node.js 확인됨: $(node --version)"
}

# ---------------------------------------------------------------------------
# 3. Google Cloud CLI
# ---------------------------------------------------------------------------
Step "3/7 Google Cloud CLI(gcloud) 확인"
if (-not (Test-Command "gcloud")) {
    Write-Host "gcloud가 설치되어 있지 않습니다. 설치를 진행합니다..."
    winget install --id Google.CloudSDK -e --source winget --accept-package-agreements --accept-source-agreements
    Write-Host "설치가 끝났습니다. 이 창을 닫고 새 PowerShell 창에서 스크립트를 다시 실행해주세요." -ForegroundColor Yellow
    exit 0
} else {
    Write-Host "gcloud 확인됨: $(gcloud --version | Select-Object -First 1)"
}

# ---------------------------------------------------------------------------
# 4. npm 의존성 설치
# ---------------------------------------------------------------------------
Step "4/7 npm 의존성 설치"
npm install

# ---------------------------------------------------------------------------
# 5. .env 설정
# ---------------------------------------------------------------------------
Step "5/7 .env 설정"
$envPath = Join-Path $PSScriptRoot ".env"
if (Test-Path $envPath) {
    Write-Host ".env 파일이 이미 존재합니다. 기존 값을 유지합니다. (재설정하려면 .env를 삭제하고 다시 실행하세요)"
} else {
    $GcpProjectId = Read-Host "Google Cloud Project ID를 입력하세요 (예: my-project-12345)"
    while ([string]::IsNullOrWhiteSpace($GcpProjectId)) {
        $GcpProjectId = Read-Host "Project ID는 필수입니다. 다시 입력해주세요"
    }

    $GcpLocation = Read-Host "Vertex AI 리전을 입력하세요 [기본값: us-central1]"
    if ([string]::IsNullOrWhiteSpace($GcpLocation)) { $GcpLocation = "us-central1" }

    $GcpModelId = Read-Host "사용할 Gemini 모델 ID [기본값: gemini-2.0-flash-001]"
    if ([string]::IsNullOrWhiteSpace($GcpModelId)) { $GcpModelId = "gemini-2.0-flash-001" }

    $ServerPort = Read-Host "로컬 서버 포트 [기본값: 3000]"
    if ([string]::IsNullOrWhiteSpace($ServerPort)) { $ServerPort = "3000" }

    @(
        "GOOGLE_CLOUD_PROJECT_ID=$GcpProjectId"
        "GOOGLE_CLOUD_LOCATION=$GcpLocation"
        "GOOGLE_CLOUD_MODEL_ID=$GcpModelId"
        "PORT=$ServerPort"
    ) | Set-Content -Path $envPath -Encoding UTF8

    Write-Host ".env 파일이 생성되었습니다."
}

$envLines = Get-Content $envPath
$ProjectIdValue = ($envLines | Where-Object { $_ -match '^GOOGLE_CLOUD_PROJECT_ID=' }) -replace '^GOOGLE_CLOUD_PROJECT_ID=', ''

# ---------------------------------------------------------------------------
# 6. Google 인증 (ADC)
# ---------------------------------------------------------------------------
Step "6/7 Google Cloud 인증 (Application Default Credentials)"
Write-Host "브라우저 창이 열립니다. Google 계정으로 로그인 후 권한을 승인해주세요."
gcloud auth application-default login

Write-Host "gcloud 기본 프로젝트를 $ProjectIdValue 로 설정합니다..."
gcloud config set project "$ProjectIdValue" | Out-Null
try {
    gcloud auth application-default set-quota-project "$ProjectIdValue" | Out-Null
} catch {
    Warn "quota project 설정에 실패했습니다. 계속 진행합니다."
}

Write-Host "Vertex AI User 권한(roles/aiplatform.user)을 확인/부여합니다..."
$CurrentAccount = gcloud config get-value account 2>$null
if (-not [string]::IsNullOrWhiteSpace($CurrentAccount)) {
    try {
        gcloud projects add-iam-policy-binding "$ProjectIdValue" `
            --member="user:$CurrentAccount" `
            --role="roles/aiplatform.user" `
            --condition=None | Out-Null
        Write-Host "권한 부여 완료 ($CurrentAccount)"
    } catch {
        Warn "권한 부여에 실패했습니다. 이미 권한이 있거나, 소유자 권한이 없는 프로젝트일 수 있습니다. 필요하면 프로젝트 관리자에게 요청하세요."
    }
}

Write-Host "Vertex AI API를 활성화합니다 (aiplatform.googleapis.com)..."
try {
    gcloud services enable aiplatform.googleapis.com --project "$ProjectIdValue" | Out-Null
    Write-Host "API 활성화 완료"
} catch {
    Warn "API 활성화에 실패했습니다. Google Cloud Console에서 직접 활성화해주세요: https://console.cloud.google.com/apis/library/aiplatform.googleapis.com"
}

# ---------------------------------------------------------------------------
# 7. 완료 및 서버 실행
# ---------------------------------------------------------------------------
Step "7/7 설치 완료"
Write-Host "모든 준비가 끝났습니다!"
Write-Host ""
$StartNow = Read-Host "지금 서버를 시작할까요? (y/N)"
if ($StartNow -match '^[Yy]') {
    npm run start
} else {
    Write-Host "나중에 서버를 시작하려면 다음 명령을 실행하세요:"
    Write-Host "  npm run start"
}
