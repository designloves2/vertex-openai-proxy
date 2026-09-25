# Changelog — Vertex OpenAI Proxy

All notable changes and architectural overhauls to the **Vertex AI to OpenAI Proxy** project are documented below.

---

## [Major Update] Vertex AI / OpenAI Compatible Proxy Overhaul

### 1. Google Vertex AI 인증 방식 개선 (Google Cloud ADC 적용)
- **이전 문제:**
  - 기존 인증 코드가 OAuth Client 기반의 `auth.js`를 사용하도록 되어 있어 `invalid_client` 에러가 발생.
  - Vertex AI OpenAI 호환 API 연동 방식에 맞지 않는 복잡성 존재.
- **개선 내용:**
  - `google-auth-library`의 `GoogleAuth`를 사용하도록 구조 전면 변경.
  - Google Cloud Application Default Credentials(ADC) 기반으로 자동 인증 수행.
- **결과:**
  - 별도의 OAuth Client ID/Secret 설정 없이 `gcloud auth application-default login` 명령어만으로 즉시 인증 가능.
  - 프록시 서버 시작 시 ADC를 정상적으로 인식하여 안전하고 간결한 인증 처리.

---

### 2. 요청된 Gemini 모델의 정확한 전달 (동적 모델 라우팅)
- **이전 문제:**
  - 클라이언트(Chatbox 등)에서 `gemini-3.6-flash`를 요청해도 Proxy 내부의 `.env` 기본 모델(예: `gemini-3.8-flash`)로 강제 덮어쓰기되는 문제.
- **개선 내용:**
  - `resolveVertexModel()` 함수 개선.
  - 클라이언트가 전달한 `model` 파라미터 값을 최우선으로 반영하며, 필요한 경우에만 별칭(Alias) 변환 수행.
- **동작 흐름:**
  ```text
  Chatbox (model: gemini-3.6-flash)
      ↓
  Proxy (gemini-3.6-flash)
      ↓
  Vertex AI (gemini-3.6-flash)
  ```

---

### 3. Gemini 3 Flash용 Generation Config 최적화
- **이전 문제:**
  - Gemini 3 Flash 계열과 기존 Gemini 모델의 Generation 파라미터 처리 방식이 동일하게 적용되어 모델 특성에 맞는 추론이 어려웠음.
- **개선 내용:**
  - Gemini 3.x Flash 모델(`^gemini-3\.\d+-flash$` 정규식) 감지 로직 추가.
  - Gemini 3 Flash에서는 불필요한 기본 temperature/topP/topK 파라미터를 강제하지 않고 모델 기본 동작 유지.
  - `thinkingConfig`를 Gemini 3 Flash 모델에 맞춰 구성 (`thinkingLevel: "high"`).

---

### 4. SSE Streaming 파서 전면 재작성 (Data Chunking & Buffer)
- **이전 문제:**
  - Vertex AI가 유효한 SSE 스트리밍 데이터를 반환함에도 불구하고 `Could not parse SSE event` 및 `Candidate=false` 오류 발생.
  - 스트리밍 응답이 여러 chunk로 쪼개져 전달될 때 JSON 경계 처리가 취약했음.
- **개선 내용:**
  - SSE 응답을 `data:` 라인 기준으로 직접 분할/파싱하도록 재작성.
  - 불완전한 chunk는 내부 버퍼에 보관 후, 완전한 `data:` JSON이 수신되었을 때만 안전하게 `JSON.parse` 수행.
  - `event:` 및 빈 라인 등 SSE 표준 프로토콜 구조 완벽 지원.
- **결과:**
  - 일반 텍스트 스트리밍 안정화 (`[V1/STREAM] Completed. Candidate=true, Text=true, ToolCall=false`).

---

### 5. Gemini 3 Function Calling 및 `thought_signature` 상태 관리 구현
- **이전 문제:**
  - OpenAI `tool_calls` 형식을 Gemini `functionCall` 형식으로 변환하는 과정에서, Gemini 3 계열에 필수적인 `thought_signature`가 다음 턴(Turn)으로 전달되지 않음.
  - 첫 번째 tool call 이후 다음 턴에서 `Function call is missing a thought_signature (400 Bad Request)` 에러 발생.
- **개선 내용:**
  - Gemini가 반환한 `functionCall` 내부의 `thought_signature` / `thoughtSignature`를 추출.
  - LRU 기반 Tool Call Cache(`toolCallData`)에 `call_id`와 함께 보존.
  - 클라이언트의 다음 턴 요청 시 OpenAI 메시지를 Gemini 컨텐츠로 변환할 때 해당 `thought_signature`를 복원하여 삽입.

---

### 6. LRU 기반 Tool Call Cache 도입
- **개선 내용:**
  - 메모리 누수를 방지하기 위해 최대 1,000건의 Tool Call 메타데이터를 유지하는 LRU 캐시 구현.
  - `call_id` ↔ `{ name, signature }` 구조로 상태 저장.
  - 클라이언트 환경에 따라 `tool_call_id`가 변경되는 경우를 대비한 `toolSignatureByName` 폴백 매핑 지원.

---

### 7. 스트리밍 중 Gemini Tool Signature 실시간 캡처
- **개선 내용:**
  - 스트리밍 파서에서 candidate 파트의 `part.thought_signature` 및 `part.thoughtSignature`를 실시간으로 탐색 및 캡처.
  - `emitToolCall()` 호출 시 캡처된 서명을 함께 전달하여 즉시 캐시에 등록.

---

### 8. Multi-turn 요청 시 Tool Call Signature 자동 복원
- **개선 내용:**
  - `openAiMessagesToGeminiContents()` 변환기에서 이전 어시스턴트 메시지의 `tool_calls` 목록을 확인.
  - 캐시에서 해당 `tool_call_id`의 서명을 검색하여 Gemini의 `functionCall` 파트에 복원.
- **동작 흐름:**
  ```text
  OpenAI tool_call
        ↓
  toolCallData 캐시 조회
        ↓
  signature 존재 시 복원
        ↓
  Gemini functionCall + thought_signature
  ```

---

### 9. Tool Response와 원래 Function Name 연결 복원
- **이전 문제:**
  - OpenAI의 `tool` 역할 메시지에는 `tool_call_id`만 있고 실제 함수명이 생략되는 경우가 존재하여 Gemini `functionResponse.name` 매핑 실패.
- **개선 내용:**
  - `tool_call_id`를 기반으로 캐시된 원래 함수 이름을 조회하여 복원.
  - 메시지에 명시된 name이 있으면 우선 사용하고, 없으면 캐시된 name을 사용하여 안정적인 `functionResponse` 생성.

---

### 10. Tool Signature 진단 로깅 추가
- **개선 내용:**
  - Multi-turn 대화 중 서명 유실 문제를 즉시 디버깅할 수 있도록 모델 요청 전 시그니처 보유 여부를 출력하는 상세 로깅 추가.
  - `[V1/CHAT] Model tool-call signatures: [ { name: 'list_files', hasThoughtSignature: true } ]`

---

### 11. Multi-turn Tool Calling 전체 End-to-End Flow 검증
- **검증된 전체 호출 사이클:**
  ```text
  Chatbox (요청)
      ↓
  Proxy (인증 및 모델 라우팅)
      ↓
  Vertex AI (Gemini 3.x Flash)
      ↓
  functionCall + thought_signature 생성
      ↓
  Proxy (thought_signature 캡처 및 캐싱)
      ↓
  Chatbox (Tool 실행 및 결과 반환)
      ↓
  Proxy (thought_signature 및 function name 복원)
      ↓
  Vertex AI (Gemini 3.x Flash - 2차 호출)
      ↓
  최종 텍스트 스트리밍 답변 완료
  ```

---

## 📊 주요 변경 내역 요약

| 영역 | 원본 문제 | 개선 내용 및 현재 상태 |
| :--- | :--- | :--- |
| **Vertex 인증** | OAuth client 방식 오류 | `google-auth-library` 기반 Google ADC 적용 완료 |
| **모델 라우팅** | `.env` 모델로 강제 변환 | 클라이언트 요청 모델 우선 적용 및 별칭 지원 |
| **Gemini 3 Flash 설정** | 일반 모델과 동일 처리 | Gemini 3 전용 `thinkingConfig` 처리 |
| **SSE 파싱** | chunk 분할 시 parse 실패 | Buffer 기반 라인 단위 JSON 파서로 전면 재작성 |
| **Streaming** | 응답 누락 및 파싱 실패 | 정상 동작 확인 완료 |
| **Function Calling** | Gemini 3 multi-turn 400 에러 | `thought_signature` 캡처 / 저장 / 복원 파이프라인 구현 |
| **상태 관리** | Tool Call 메타데이터 미보존 | LRU Cache (`toolCallData`) 추가 |
| **Tool Response 매핑** | Function Name 누락 문제 | `tool_call_id` 기반 함수명 복원 로직 추가 |
| **진단 로깅** | 디버깅 정보 부족 | Tool Call Signature 상태 진단 로그 추가 |
| **Multi-turn Tool Call** | 400 에러 발생 | Chatbox Tool Use 전체 Flow 검증 완료 |

---

## 📌 지원 범위 및 참고 사항
- 현재 **`POST /v1/chat/completions`** 엔드포인트를 중심으로 Vertex AI Gemini 3.x 시리즈의 텍스트 생성, 스트리밍, Multi-turn Function Calling이 완벽하게 지원됩니다.
- Chatbox, Cline 등 OpenAI 호환 클라이언트에서 별도의 복잡한 설정 없이 로컬 프록시를 통해 Vertex AI의 최신 Gemini 모델을 원활하게 활용할 수 있습니다.
