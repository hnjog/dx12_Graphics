# AI Review Workflow

## 목적

이 문서는 `dx12_Graphics` 저장소에서 AI 리뷰를 실제로 어떤 흐름으로 실행하고, 어떤 기준으로 평가하며, 언제 Slack으로 알림을 보내는지 정리합니다.
핵심은 AI 리뷰를 사람 리뷰의 대체물이 아니라, PR 단계에서 반복적으로 실행되는 보조 리뷰어로 운영하는 것입니다.

## 적용 범위

- 기본 대상은 `feature/... -> develop` PR입니다.
- `develop -> main` PR은 이후 운영이 안정화되면 같은 흐름을 확장해서 적용합니다.
- 현재 단계에서는 GitHub Actions가 PR 기준으로 AI 리뷰를 실행하고, 사람은 결과를 검토해 최종 판단합니다.

## 필요한 준비물

### GitHub Secrets

- `OPENAI_API_KEY`: AI 리뷰 실행에 필요한 필수 Secret
- `SLACK_WEBHOOK_URL`: Slack 알림이 필요할 때 사용하는 선택 Secret

### GitHub Variables

- `OPENAI_MODEL`: 선택 변수. 지정하지 않으면 workflow 기본값을 사용합니다.

## PR 작성자 기대 사항

- PR 대상 브랜치를 정확히 선택합니다. 기본 개발 기능은 `develop` 대상으로 보냅니다.
- `.github/pull_request_template.md`에 있는 항목을 가능한 한 빠짐없이 작성합니다.
- 빌드 또는 수동 검증 결과를 남깁니다.
- AI가 특히 봐야 할 리스크와 리뷰 제외 범위를 적어둡니다.

## PR 접수 후 흐름

1. 작성자가 `feature/... -> develop` PR을 엽니다.
2. GitHub Actions의 `ai_review.yml`이 `pull_request` 이벤트에서 실행됩니다.
3. workflow는 PR 제목, PR 본문, base/head diff, `docs/review-rules.md`, `docs/testing-strategy.md`를 함께 수집합니다.
4. 수집한 입력을 OpenAI Responses API에 보내 리뷰 결과를 JSON 형식으로 받습니다.
5. workflow는 결과를 Markdown으로 정리해 PR 코멘트와 Actions summary에 남깁니다.
6. `Blocker` 또는 `Major`가 있거나 workflow 자체가 실패한 경우, Slack Webhook이 설정되어 있으면 요약 알림을 보냅니다.
7. 사람 리뷰어가 AI 결과와 실제 변경 의도를 함께 보고 최종 판단합니다.

## 평가 방식

AI 리뷰는 `docs/review-rules.md`를 기준으로 아래 우선순위를 따릅니다.

1. 크래시, 메모리 손상, 핸들 누수 가능성
2. DirectX 12 리소스 수명 및 동기화 문제
3. 상태 전이, API 오용, 초기화 누락
4. 기능 회귀 및 테스트 누락
5. 성능 저하 가능성
6. 유지보수성 문제
7. 스타일 및 표현 개선

심각도는 아래와 같이 해석합니다.

- `Blocker`: 머지하면 안 되는 수준
- `Major`: 기능 안정성이나 회귀 가능성에 큰 영향
- `Minor`: 수정 권장
- `Suggestion`: 개선 제안

초기 운영 원칙은 아래와 같습니다.

- AI 결과만으로 자동 머지 차단을 결정하지 않습니다.
- `Blocker`와 `Major`는 사람 리뷰가 반드시 다시 확인합니다.
- `Minor`와 `Suggestion`은 PR 코멘트에 남기되, Slack 알림 기본 대상에서는 제외합니다.
- AI가 확신이 낮은 경우에도 단정하지 않고 가정임을 드러내야 합니다.

## Slack 알림 방식

현재 추천 방식은 Slack Incoming Webhook입니다.

- Slack App에서 Incoming Webhook을 활성화합니다.
- 알림을 받을 채널을 선택해 webhook URL을 발급받습니다.
- 발급된 URL을 `SLACK_WEBHOOK_URL` GitHub Secret으로 저장합니다.

Slack으로 보내는 기본 정보는 아래와 같습니다.

- PR 제목과 링크
- 대상 브랜치와 소스 브랜치
- AI 리뷰 상태
- `Blocker`, `Major`, `Minor`, `Suggestion` 개수
- 가장 중요한 한 줄 요약

기본 알림 조건은 아래를 권장합니다.

- `Blocker` 또는 `Major` 발견 시
- workflow 자체 실패 시

## 운영 메모

- fork에서 들어오는 PR은 repository secret을 사용할 수 없으므로 AI 리뷰가 skip될 수 있습니다.
- AI 리뷰는 기계적 검증을 대체하지 않습니다. 빌드, 실행, 수동 확인 기록은 계속 필요합니다.
- workflow가 안정화되면 이후에는 `develop -> main` PR에도 같은 흐름을 확장할 수 있습니다.

## 초기 도입 체크리스트

1. `OPENAI_API_KEY` Secret 추가
2. 필요하면 `OPENAI_MODEL` Variable 추가
3. 필요하면 `SLACK_WEBHOOK_URL` Secret 추가
4. `feature/... -> develop` PR 생성
5. PR 코멘트와 Actions summary 결과 확인
6. Slack 알림 조건이 의도대로 동작하는지 확인
