# 이미지 생성 앱 명세서 (v1)

작성: 2026-11-26. 새 세션은 이 문서와 아래 참고 문서를 먼저 읽고 시작하세요.

- 프록시 사용법(필독): [`docs/client-app-dev-guide.md`](client-app-dev-guide.md)
- 프록시 내부 동작: [`docs/macos-swift-image-models-handoff.md`](macos-swift-image-models-handoff.md)
- 기존 Windows 앱 UI 결정사항(디자인 기준): 루트 `CLAUDE.md`의 "WinUI 3 app" 절

---

## 1. 목표

Vertex OpenAI Proxy(로컬 `http://127.0.0.1:3000`)를 통해 Google의 이미지 모델로
**대화하듯 이미지를 생성하고 계속 수정**하는 데스크톱 앱.

- 대화 기록과 생성 이미지가 **영구 저장**되어 앱을 다시 켜도, 다음 날에도 이어서 작업.
- "더 밝게", "배경만 바꿔줘"처럼 **이전 결과를 기준으로 수정**.
- 참조 이미지(사진, 스케치) 첨부해서 편집/스타일 지정.
- 나중에 ComfyUI custom node를 만들 때 재사용할 수 있게 **프록시 호출 로직은 UI와 분리**.

비목표(v1에서 안 함): 동영상(Veo), 인페인팅 마스크 그리기, 클라우드 동기화, 계정/로그인.

## 2. 플랫폼 / 기술

| 항목 | 결정 |
|---|---|
| Windows | **C# / WinUI 3 (Windows App SDK)**, unpackaged + self-contained. 프록시 앱(`gui-win/`)과 같은 스택·디자인 언어 |
| macOS | 별도 Swift/SwiftUI 앱으로 나중에 (이 문서의 기능/데이터 구조를 그대로 따름) |
| 저장소 | **새 저장소 권장** (예: `vertex-image-studio`). 이 저장소에 넣을 경우 `image-app/` 폴더 |
| DB | SQLite (`Microsoft.Data.Sqlite`) |
| HTTP | `HttpClient` (OpenAI SDK 없이 직접 호출 — 응답 형식이 단순함) |
| 빌드 | .NET 8 SDK. 회사 PC는 `%LOCALAPPDATA%\Microsoft\dotnet`에 사용자 설치되어 있음. 집 PC는 없으면 `winget install Microsoft.DotNet.SDK.8` 또는 dotnet-install 스크립트 |

프로젝트 구조(권장):

```
ImageStudio/
  ImageStudio.Core/        # UI 없는 라이브러리: 프록시 클라이언트, 저장소, 히스토리 빌더 (ComfyUI 노드 포팅 시 참고)
  ImageStudio.App/         # WinUI 3 앱
  ImageStudio.Tests/       # Core 단위 테스트 (xUnit)
```

## 3. 화면 구성

프록시 앱과 같은 방식: Mica 배경, 커스텀 타이틀바, **왼쪽 위 톱니바퀴 = 설정**, 설정 화면은 ← 버튼만.
창 크기에 맞춰 반응형(코드로 처리, AdaptiveTrigger 사용 안 함 — Window 직속에서 불안정했음).

```
┌──────────────────────────────────────────────────────────────────┐
│ ⚙  Image Studio                                     ─  ☐  ✕     │
├───────────────┬──────────────────────────────────────────────────┤
│ [+ 새 대화]    │  모델 [gemini-3.1-flash-image ▾]  비율 [1:1 ▾]  개수 [1▾] │
│ 🔍 검색        │──────────────────────────────────────────────────│
│ ─────────────  │                                                  │
│ 오늘           │   (user)  파란 원 아이콘 그려줘                   │
│  ▸ 아이콘 작업  │   (assistant) [이미지][이미지]  설명 텍스트        │
│  ▸ 로고 시안    │        ↳ [이걸로 계속] [저장] [복사] [다시 생성]  │
│ 어제           │   (user)  빨간색으로 바꿔줘                        │
│  ▸ ...         │   (assistant) [이미지]                           │
│               │                                                  │
│               │──────────────────────────────────────────────────│
│               │ [📎 첨부 썸네일들]                                 │
│               │ [ 프롬프트 입력 (Enter 전송, Shift+Enter 줄바꿈) ] [생성] │
└───────────────┴──────────────────────────────────────────────────┘
```

- **왼쪽: 대화 목록** — 최근 순, 날짜 그룹, 이름 변경/삭제(휴지통 → 30일 후 영구 삭제), 검색(제목+프롬프트).
  좁은 창에서는 접힘(햄버거 버튼).
- **가운데: 대화** — 메시지 버블. 이미지 썸네일 클릭 시 큰 미리보기(줌/패닝, 좌우 넘기기).
- **이미지별 액션**: 이걸로 계속(다음 요청의 기준 이미지로 지정), 저장(PNG 다른 이름으로), 클립보드 복사,
  폴더 열기, 다시 생성(같은 요청 재실행, 캐시 우회).
- **입력창**: 드래그&드롭/붙여넣기(Ctrl+V)로 참조 이미지 첨부, 생성 중엔 진행 표시 + 취소 버튼.
- **상단 옵션**: 모델, 비율(`1:1, 16:9, 9:16, 4:3, 3:4, 3:2, 2:3`), 개수(1–4).
- **설정**: 프록시 주소(기본 `http://127.0.0.1:3000`) + 연결 테스트, 저장 폴더, 기록에 포함할 최근 이미지 수(기본 3),
  요청 타임아웃(기본 300초), 테마(시스템/라이트/다크).

## 4. 프록시 연동 (핵심)

자세한 형식은 `client-app-dev-guide.md` 4장. 요약:

1. **모델 목록**: `GET /v1/models?type=image` → 드롭다운. 마지막 선택 모델 기억.
   목록에 있어도 프로젝트 권한이 없으면 404가 남 → 에러 메시지 그대로 표시하고 그 모델에 ⚠ 표시.
   (테스트 프로젝트에서 동작 확인: `gemini-2.5-flash-image`, `gemini-3.1-flash-image`. Imagen은 404.)
2. **생성/수정 (기본 경로)**: `POST /v1/chat/completions`, `stream: false`
   - body: `model`, `aspect_ratio`, `n`, `messages`(대화 전체, 아래 5장 규칙대로 구성)
   - 응답 `choices[0].message.content`에서 정규식
     `!\[[^\]]*\]\((data:([^;]+);base64,([A-Za-z0-9+/=]+))\)` 로 이미지 추출, 나머지는 설명 텍스트.
3. **Imagen 모델**: 대화/편집 불가. 같은 경로로 보내면 마지막 user 텍스트만 쓰임.
   UI에서 Imagen 선택 시 "단발 생성 모델 — 이전 이미지를 기억하지 않음" 안내 표시, 첨부 비활성화.
4. **에러 처리**: HTTP 타임아웃 300초. 429 → "쿼터 초과, 잠시 후 재시도" + 재시도 버튼.
   400(안전 필터 등) → 모델이 준 메시지 표시. 프록시 미실행(연결 거부) → "프록시 앱을 실행하세요" 배너.
   프록시는 이미지 요청에 대해 120초 타임아웃 + 1회 자동 재시도를 이미 함.

## 5. 대화 기억 / 캐시 (필수)

프록시는 stateless. **앱이 대화를 저장하고 매 요청마다 기록을 다시 보낸다.**

### 저장 구조 (SQLite, `%LOCALAPPDATA%\ImageStudio\studio.db`)

```sql
conversations(id TEXT PK, title TEXT, model TEXT, aspect_ratio TEXT,
              created_at INTEGER, updated_at INTEGER, deleted_at INTEGER NULL)
messages(id TEXT PK, conversation_id TEXT, seq INTEGER, role TEXT,  -- user|assistant|system
         text TEXT, model TEXT, status TEXT,                       -- ok|error|cancelled
         error TEXT NULL, created_at INTEGER)
images(id TEXT PK, message_id TEXT, idx INTEGER, sha1 TEXT, mime TEXT,
       path TEXT, width INTEGER, height INTEGER, kind TEXT)         -- generated|attached
response_cache(key TEXT PK, message_id TEXT, created_at INTEGER)
```

- **이미지는 파일**로: `<저장폴더>\<conversation_id>\<sha1>.png`. DB에는 경로/sha1만.
- **원본 그대로 저장**: 응답 base64를 디코드한 바이트를 그대로 파일로. 리사이즈/재인코딩 금지
  (프록시가 Gemini 3용 thought signature를 이미지 base64의 sha1로 찾음 — 바이트가 바뀌면 못 찾음).
- 제목: 첫 프롬프트 앞 40자로 자동, 사용자가 변경 가능.

### 요청 기록 구성 규칙 (`HistoryBuilder`, Core에 두고 단위 테스트)

- system 메시지(설정의 기본 지시문, 선택)를 맨 앞에.
- 지난 턴들을 순서대로: user → 텍스트 + 첨부 이미지(`image_url` 파트, data URI),
  assistant → 텍스트 + `![image N](data:...)` (원본 파일을 base64로 복원).
- **용량 제한**: 최근 N장(기본 3)의 이미지만 실제로 포함. 그보다 오래된 이미지는
  `[이전 이미지: <프롬프트 요약>]` 텍스트로 대체. 요청 본문 40MB 넘으면 N을 줄여 재구성 (프록시 한도 50MB).
- "이걸로 계속"으로 특정 이미지를 지정하면 그 이미지는 N에 상관없이 반드시 포함.
- 실패/취소된 턴은 기록에서 제외.
- 시스템 프롬프트와 이전 메시지는 매번 **같은 순서·같은 내용**으로 (Gemini implicit caching 효과).

### 응답 캐시

- key = sha256(model + aspect_ratio + n + 정규화된 messages JSON).
- 같은 key 요청은 저장된 결과 재사용 (앱 재시작 후에도). "다시 생성"은 캐시 우회 후 새 결과 추가.

## 6. 구현 단계 (마일스톤)

1. **M1 Core**: 프록시 클라이언트(모델 목록, chat completions, 이미지 추출), SQLite 저장소, HistoryBuilder + 단위 테스트.
2. **M2 기본 UI**: 대화 1개에서 프롬프트 → 이미지 표시 → 이어서 수정. 결과가 DB/파일에 저장되고 재시작 후 복원.
3. **M3 대화 관리**: 목록, 새 대화, 이름 변경, 삭제/휴지통, 검색.
4. **M4 편의 기능**: 첨부(드래그/붙여넣기), 이미지 뷰어, 저장/복사/폴더 열기, 다시 생성, 응답 캐시, 취소.
5. **M5 마감**: 설정 화면, 에러 배너, 반응형 점검(창 크기별 스크린샷 확인), 아이콘, 배포 스크립트(portable zip) + 자동 업데이트(프록시 앱 `gui-win/Core/Updater.cs` 방식 재사용, 태그 접두사만 다르게 예: `studio-v`).

각 단계 끝에 **실제 앱을 띄워 스크린샷으로 UI를 확인**할 것 (프록시 앱 작업 때 UI 미확인으로 다시 만든 적 있음).
캡처는 `PrintWindow`(flag 2) 사용 — WinUI 창에서 `CopyFromScreen`은 잘못 찍힘.

## 7. 완료 기준 (v1)

- [ ] 프록시 연결 테스트 성공/실패가 화면에 표시됨
- [ ] `gemini-3.1-flash-image`로 생성 → "빨간색으로" 수정이 이전 이미지를 기준으로 동작
- [ ] 앱 종료 후 재실행해도 대화/이미지가 그대로이고 이어서 수정 가능
- [ ] 참조 이미지 첨부해서 편집 가능
- [ ] 이미지 10장 이상 쌓인 대화에서도 요청이 한도 내로 구성됨 (HistoryBuilder 테스트)
- [ ] 429/404/400/프록시 꺼짐 각각 이해 가능한 메시지
- [ ] 창을 좁게/넓게 했을 때 글자 잘림·고정 크기 없음
- [ ] portable zip 빌드

## 8. 나중에 (v1 이후)

- **ComfyUI custom node**: `POST /v1/images/generations` (stateless, `b64_json`) 사용이 가장 단순.
  입력: prompt, model, aspect_ratio, n, 선택적 image 텐서 → 출력: IMAGE 텐서 배치. Core의 요청/응답 형식을 Python으로 옮기면 됨.
- macOS 버전 (SwiftUI, 같은 DB 스키마).
- 프롬프트 템플릿/스타일 프리셋, 이미지 비교(전/후 슬라이더), 배치 생성.
