#!/usr/bin/env bash
#
# One-shot installer for vertex-openai-proxy on macOS.
# Installs prerequisites, authenticates with Google Cloud (ADC),
# writes .env, installs npm dependencies, and optionally starts the server.
#
# Usage:
#   chmod +x install-mac.sh
#   ./install-mac.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
RESET='\033[0m'

step() { echo -e "\n${BOLD}${GREEN}==> $1${RESET}"; }
warn() { echo -e "${YELLOW}[WARN] $1${RESET}"; }
err()  { echo -e "${RED}[ERROR] $1${RESET}"; }

# ---------------------------------------------------------------------------
# 1. Homebrew
# ---------------------------------------------------------------------------
step "1/8 Homebrew 확인"
if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew가 설치되어 있지 않습니다. 설치를 진행합니다..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [[ -d "/opt/homebrew/bin" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
else
    echo "Homebrew 확인됨: $(brew --version | head -1)"
fi

# ---------------------------------------------------------------------------
# 2. Node.js
# ---------------------------------------------------------------------------
step "2/8 Node.js 확인"
if ! command -v node >/dev/null 2>&1; then
    echo "Node.js가 설치되어 있지 않습니다. 설치를 진행합니다..."
    brew install node
else
    echo "Node.js 확인됨: $(node --version)"
fi

# ---------------------------------------------------------------------------
# 3. Google Cloud CLI
# ---------------------------------------------------------------------------
step "3/8 Google Cloud CLI(gcloud) 확인"
if ! command -v gcloud >/dev/null 2>&1; then
    echo "gcloud가 설치되어 있지 않습니다. 설치를 진행합니다..."
    brew install --cask google-cloud-sdk
    # google-cloud-sdk installs into Caskroom; source its path helper for this shell
    GCLOUD_SDK_PATH="$(brew --prefix)/share/google-cloud-sdk/path.bash.inc"
    if [[ -f "$GCLOUD_SDK_PATH" ]]; then
        source "$GCLOUD_SDK_PATH"
    fi
else
    echo "gcloud 확인됨: $(gcloud --version | head -1)"
fi

if ! command -v gcloud >/dev/null 2>&1; then
    err "gcloud 설치 후에도 명령을 찾을 수 없습니다. 터미널을 새로 열고 다시 실행해주세요."
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. npm dependencies
# ---------------------------------------------------------------------------
step "4/8 npm 의존성 설치"
npm install

# ---------------------------------------------------------------------------
# 5. .env 설정
# ---------------------------------------------------------------------------
step "5/8 .env 설정"
if [[ -f ".env" ]]; then
    echo ".env 파일이 이미 존재합니다. 기존 값을 유지합니다. (재설정하려면 .env를 삭제하고 다시 실행하세요)"
else
    read -rp "Google Cloud Project ID를 입력하세요 (예: my-project-12345): " GCP_PROJECT_ID
    while [[ -z "$GCP_PROJECT_ID" ]]; do
        read -rp "Project ID는 필수입니다. 다시 입력해주세요: " GCP_PROJECT_ID
    done

    read -rp "Vertex AI 리전을 입력하세요 [기본값: us-central1]: " GCP_LOCATION
    GCP_LOCATION="${GCP_LOCATION:-us-central1}"

    read -rp "사용할 Gemini 모델 ID [기본값: gemini-2.0-flash-001]: " GCP_MODEL_ID
    GCP_MODEL_ID="${GCP_MODEL_ID:-gemini-2.0-flash-001}"

    read -rp "로컬 서버 포트 [기본값: 3000]: " SERVER_PORT
    SERVER_PORT="${SERVER_PORT:-3000}"

    cat > .env <<EOF
GOOGLE_CLOUD_PROJECT_ID=${GCP_PROJECT_ID}
GOOGLE_CLOUD_LOCATION=${GCP_LOCATION}
GOOGLE_CLOUD_MODEL_ID=${GCP_MODEL_ID}
PORT=${SERVER_PORT}
EOF
    echo ".env 파일이 생성되었습니다."
fi

# shellcheck disable=SC1091
source .env 2>/dev/null || true
PROJECT_ID_VALUE="$(grep -E '^GOOGLE_CLOUD_PROJECT_ID=' .env | cut -d '=' -f2-)"

# ---------------------------------------------------------------------------
# 6. Google 인증 (ADC)
# ---------------------------------------------------------------------------
step "6/8 Google Cloud 인증 (Application Default Credentials)"
echo "브라우저 창이 열립니다. Google 계정으로 로그인 후 권한을 승인해주세요."
gcloud auth application-default login

echo "gcloud 기본 프로젝트를 ${PROJECT_ID_VALUE}로 설정합니다..."
gcloud config set project "${PROJECT_ID_VALUE}" >/dev/null
gcloud auth application-default set-quota-project "${PROJECT_ID_VALUE}" >/dev/null || true

echo "Vertex AI User 권한(roles/aiplatform.user)을 확인/부여합니다..."
CURRENT_ACCOUNT="$(gcloud config get-value account 2>/dev/null)"
if [[ -n "$CURRENT_ACCOUNT" ]]; then
    gcloud projects add-iam-policy-binding "${PROJECT_ID_VALUE}" \
        --member="user:${CURRENT_ACCOUNT}" \
        --role="roles/aiplatform.user" \
        --condition=None >/dev/null 2>&1 \
        && echo "권한 부여 완료 (${CURRENT_ACCOUNT})" \
        || warn "권한 부여에 실패했습니다. 이미 권한이 있거나, 소유자 권한이 없는 프로젝트일 수 있습니다. 필요하면 프로젝트 관리자에게 요청하세요."
fi

echo "Vertex AI API를 활성화합니다 (aiplatform.googleapis.com)..."
gcloud services enable aiplatform.googleapis.com --project "${PROJECT_ID_VALUE}" >/dev/null 2>&1 \
    && echo "API 활성화 완료" \
    || warn "API 활성화에 실패했습니다. Google Cloud Console에서 직접 활성화해주세요: https://console.cloud.google.com/apis/library/aiplatform.googleapis.com"

# ---------------------------------------------------------------------------
# 7. 실행용 스크립트 생성
# ---------------------------------------------------------------------------
step "7/8 실행용 스크립트 생성"
RUN_SCRIPT_PATH="$SCRIPT_DIR/vertex-openai-proxy-run.sh"
cat > "$RUN_SCRIPT_PATH" <<'EOF'
#!/usr/bin/env bash
# Double-click (or run) this script to start the vertex-openai-proxy server.
cd "$(dirname "${BASH_SOURCE[0]}")"
npm run start
EOF
chmod +x "$RUN_SCRIPT_PATH"
echo "생성됨: $RUN_SCRIPT_PATH"
echo "다음부터는 터미널에서 ./vertex-openai-proxy-run.sh 를 실행하면 서버가 시작됩니다."
echo "Finder에서 더블클릭으로 실행하려면: 파일 우클릭 > 정보 가져오기 > '다음 프로그램으로 열기'에서 터미널을 선택하세요."

# ---------------------------------------------------------------------------
# 8. 완료 및 서버 실행
# ---------------------------------------------------------------------------
step "8/8 설치 완료"
echo "모든 준비가 끝났습니다!"
echo ""
read -rp "지금 서버를 시작할까요? (y/N): " START_NOW
if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
    npm run start
else
    echo "나중에 서버를 시작하려면 다음 명령을 실행하세요:"
    echo "  ./vertex-openai-proxy-run.sh"
fi
