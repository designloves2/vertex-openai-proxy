# 클라이언트 앱 개발 가이드 — Vertex OpenAI Proxy 사용하기

이미지 생성 앱 / 대화형 LLM 앱(그리고 추후 ComfyUI custom node)을 만드는
세션이 **가장 먼저 읽어야 하는 문서**입니다. 프록시 자체 수정이 아니라,
프록시에 붙는 앱을 만드는 쪽 기준으로 정리했습니다.

- 프록시: 이 저장소의 `index.js` (Windows: `gui-rs/` 트레이 앱이 실행, macOS: 별도 Swift 앱)
- 기본 주소: `http://127.0.0.1:3000` (`.env`의 `PORT`)
- 인증: 프록시가 Google ADC로 처리 → **앱은 API 키 불필요** (OpenAI SDK를 쓸 경우 아무 문자열이나 `apiKey`로 넣으면 됨)
- 관련 문서: `docs/macos-swift-image-models-handoff.md` (프록시 내부 동작 상세)

---

## 1. 핵심 원칙

1. **모델은 앱이 고른다.** 매 요청의 `model` 필드가 그대로 Vertex 모델로 쓰입니다.
   프록시 `.env`의 모델은 `model`이 비어 있을 때만 쓰는 기본값입니다.
   앱에는 `/v1/models`로 받은 목록에서 고르는 UI를 두세요.
2. **프록시는 대화 상태를 저장하지 않는다 (stateless).** 대화 기억은
   **앱이 대화 기록 전체를 매 요청마다 `messages`로 다시 보내는 방식**으로 구현합니다
   (OpenAI API와 동일). 프록시는 Gemini가 요구하는 보조 데이터(thought signature)만
   메모리에 캐시합니다 — 아래 4장 참고.
3. **OpenAI 호환 형식**만 쓰면 됩니다. 공식 OpenAI SDK(JS/Python/C#)를
   `baseURL = http://127.0.0.1:3000/v1`로 지정해서 그대로 사용 가능합니다.

## 2. 모델 목록 — `GET /v1/models`

Vertex에서 사용 가능한 Google 모델 전체를 실시간 조회합니다 (프록시에서 1시간 캐시).

| 쿼리 | 의미 |
|---|---|
| `?type=chat` | 대화형 LLM만 |
| `?type=image` | 이미지 생성 모델만 (Imagen, Gemini `*-image*`) |
| `?type=chat,image` | 여러 개 동시 |
| `?refresh=1` | 캐시 무시하고 다시 조회 |

각 항목의 추가 필드: `type` (`chat`/`image`/`video`/`embedding`/`audio`/`other`),
`input_modalities`, `output_modalities`, `capabilities.{vision, reasoning, tool_use, image_generation}`.

주의: 목록에 있어도 **GCP 프로젝트에 접근 권한이 없으면 404**가 납니다
(테스트 프로젝트 기준 Imagen 전체, `gemini-3-pro-image-preview`가 404).
앱은 404/403 에러 메시지를 사용자에게 그대로 보여주고, 실패한 모델을 표시해 두는 것을 권장합니다.

테스트 프로젝트에서 동작 확인된 모델: 대화 `gemini-2.5-flash`, `gemini-3.1-pro-preview` /
이미지 `gemini-2.5-flash-image`, `gemini-3.1-flash-image`.

## 3. 대화형 LLM 앱

`POST /v1/chat/completions` (스트리밍 `stream: true` 권장, SSE) 또는 `POST /v1/responses`.

```json
{
  "model": "gemini-3.1-pro-preview",
  "stream": true,
  "messages": [
    { "role": "system", "content": "..." },
    { "role": "user", "content": [
        { "type": "text", "text": "이 사진 설명해줘" },
        { "type": "image_url", "image_url": { "url": "data:image/png;base64,..." } }
    ]},
    { "role": "assistant", "content": "..." },
    { "role": "user", "content": "이어서..." }
  ],
  "tools": [ ... ]
}
```

- 이미지 입력: `data:` URI, http(s) URL, 로컬 경로 텍스트 모두 지원.
- tools / tool_calls: OpenAI 형식 그대로. assistant의 `tool_calls`와 `tool` 메시지를
  **id를 바꾸지 말고** 기록 그대로 다시 보내세요 (프록시가 id로 signature를 찾음).
- 429/5xx는 프록시가 스트리밍에서 자동 재시도(2s/3s/5s)하지만, 앱에서도 최종 실패 시
  "다시 시도" 버튼을 제공하세요.

## 4. 이미지 생성 앱

두 가지 방식이 있습니다. **대화하며 수정하는 앱이라면 A 방식**을 쓰세요.

### A. 대화형 생성/편집 — `POST /v1/chat/completions` + Gemini 이미지 모델

```json
{
  "model": "gemini-3.1-flash-image",
  "aspect_ratio": "16:9",
  "messages": [
    { "role": "system", "content": "You are an icon designer." },
    { "role": "user", "content": "파란 원 아이콘 그려줘" },
    { "role": "assistant", "content": "![image 1](data:image/png;base64,....)" },
    { "role": "user", "content": "같은 원을 빨간색으로 바꿔줘" }
  ]
}
```

- 응답 `choices[0].message.content` = 모델의 텍스트 + `![image N](data:<mime>;base64,...)`
  형태의 markdown 이미지. 앱은 정규식
  `!\[[^\]]*\]\((data:([^;]+);base64,([A-Za-z0-9+/=]+))\)`로 이미지를 꺼내 저장/표시하세요.
- **대화 기억**: 이전 assistant 응답을 받은 그대로(이미지 data URI 포함) `messages`에
  다시 넣으면, 프록시가 전체 대화를 Gemini에 전달해서 "이전 결과를 수정"이 동작합니다
  (`gemini-2.5-flash-image`로 2턴 편집 검증 완료).
- 사용자가 첨부한 참조 이미지: user 메시지에 `image_url` 파트로 넣으면 됩니다.
- `stream: true`도 되지만 이미지는 완성 후 한 번에 옵니다 (청크 1개).
- 옵션: `aspect_ratio` (`1:1`,`16:9`,`9:16`,`4:3`,`3:4`,`3:2`,`2:3`) 또는 `size` (`1024x1792` 등 → 가까운 비율로 변환), `n` (1–4, n번 호출).
- Imagen 모델을 이 방식으로 부르면 **마지막 user 메시지 텍스트만** 쓰입니다 (Imagen은 대화/편집 불가).

### B. 단발 생성 — `POST /v1/images/generations` (OpenAI Images API 형식)

```json
{ "model": "imagen-4.0-generate-001", "prompt": "...", "n": 2, "size": "1024x1024",
  "response_format": "b64_json", "images": ["data:image/png;base64,..."], "parameters": {} }
```

- 응답: `{ "created": ..., "data": [ { "b64_json": "...", "revised_prompt": "..." } ] }`
  (`response_format: "url"`이면 `url`에 data URI).
- `images`/`image`: 편집용 입력 이미지 (Gemini 이미지 모델만). `parameters`: Imagen 파라미터 그대로 전달
  (예: `negativePrompt`, `seed`, `personGeneration`).
- `model` 생략 시 프록시 `.env`의 `IMAGE_MODEL_ID` → 없으면 `imagen-4.0-generate-001`.
- ComfyUI custom node는 이 B 방식이 가장 단순합니다 (stateless, b64 → 텐서 변환).

### 타임아웃 / 에러

- 이미지 1장 생성에 보통 10–40초, 가끔 2분 가까이 걸립니다. **앱 HTTP 타임아웃은 300초 이상**으로 잡으세요.
  프록시는 Vertex 요청 하나당 120초 타임아웃 + 1회 자동 재시도(타임아웃/429/5xx)를 합니다.
- 429 "Resource exhausted" = Vertex 쿼터 초과. 앱에서 잠시 후 재시도 안내.
- 안전 필터로 막히면 400과 모델의 설명 텍스트가 에러 메시지로 옵니다.

## 5. 캐시 / 대화 기억 — 앱에서 반드시 구현할 것

프록시는 stateless이므로 **대화 기억과 캐시는 앱의 기본 기능**으로 구현합니다.

### 앱 측 (필수)

1. **대화 저장소**: 대화(conversation)별로 메시지 배열을 로컬에 영구 저장
   (SQLite 권장; 테이블 `conversations(id, title, model, created_at, updated_at)`,
   `messages(id, conversation_id, seq, role, content_json, created_at)`).
   앱 재시작 후에도 대화를 이어갈 수 있어야 합니다.
2. **이미지는 파일로, 기록에는 참조로**: 생성 이미지는 `images/<conversation_id>/<sha1>.png`
   로 저장하고 DB에는 경로/sha1만 둡니다. 요청을 보낼 때만 data URI로 복원해서 `messages`에
   넣으세요 (DB 비대화 방지). sha1은 이미지 base64의 sha1로 — 프록시의 signature 캐시 키와 동일.
3. **컨텍스트 길이 관리**: 대화가 길어지면 오래된 턴을 요약하거나 잘라서 보내세요.
   이미지 대화는 특히 무거우므로 **최근 이미지 1–3장만** 기록에 남기고 그 이전 이미지는
   텍스트 설명으로 대체하는 것을 권장합니다 (요청 본문 한도: 프록시 50MB).
4. **응답 캐시(선택)**: 같은 `model + messages + 옵션`의 해시가 같으면 저장된 결과를 재사용
   (단발 생성/재실행 시 비용 절감). seed가 없는 이미지 생성은 매번 결과가 다르므로
   "다시 생성" 버튼은 캐시를 우회해야 합니다.
5. **원본 보존**: 앱이 받은 assistant 메시지(텍스트+이미지)를 **수정 없이** 저장해 두었다가
   그대로 재전송하세요. 이미지를 리사이즈/재인코딩하면 프록시 signature 캐시와 매칭되지 않습니다
   (이 경우에도 동작은 하지만 Gemini 3 모델에서 편집 품질이 떨어질 수 있음).

### 프록시 측 (이미 구현됨 — 참고용)

- **Thought signature 캐시**: Gemini 3 계열은 이전 턴의 tool call/생성 이미지에 붙은
  `thoughtSignature`를 다시 보내야 합니다. 프록시가 메모리 LRU에 저장
  (tool call: 1000개, 이미지: 500개, 키 = 이미지 base64의 sha1)하고 재전송 시 자동으로 붙입니다.
  프록시 재시작으로 캐시가 비면 검증 생략 값으로 대체되므로 에러는 나지 않습니다.
- **모델 목록 캐시**: 1시간.
- **Gemini implicit context caching**: Vertex가 같은 앞부분(시스템 프롬프트 + 이전 대화)을
  자동으로 캐시해서 비용을 줄여 줍니다. 앱은 **시스템 프롬프트와 이전 메시지를 매번
  똑같이(앞부분 불변) 보내는 것**만 지키면 효과를 봅니다.

## 6. 체크리스트 (이미지 생성 앱 v1)

- [ ] 설정: 프록시 주소(기본 `http://127.0.0.1:3000`), 연결 테스트(`GET /health`)
- [ ] 모델 선택: `/v1/models?type=image` (+ 대화 보조용 `?type=chat`)
- [ ] 대화 목록 / 새 대화 / 대화 이어가기 (SQLite + 이미지 파일)
- [ ] 프롬프트 입력 + 참조 이미지 첨부 + 비율/개수 옵션
- [ ] 결과 이미지 표시, 저장, "이걸로 계속 수정" (A 방식), 다시 생성
- [ ] 300초 타임아웃, 429/404/400 에러 메시지 표시
- [ ] 기록 다이어트: 오래된 이미지 턴은 텍스트로 대체
