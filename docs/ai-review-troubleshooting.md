# AI Review Troubleshooting

## 목적

이 문서는 `dx12_Graphics` 저장소의 AI 리뷰 workflow를 운영하면서 발생한 문제를 기록하고, 재발 시 어떤 순서로 확인해야 하는지 정리합니다.
특히 GitHub Actions 권한 문제와 OpenAI API 호출 실패를 분리해서 판단할 수 있도록 사례 중심으로 남깁니다.

## 사례: PR #1 실행 실패

### 상황

- PR 제목: `[add] review automation - AI 리뷰 워크플로우 및 Actions 초안 추가`
- Base branch: `develop`
- Head branch: `feature/ai_review_workflow`
- 관련 workflow: `.github/workflows/ai_review.yml`

### 관찰된 증상

- Slack 알림에 `AI Review failed` 메시지가 도착했습니다.
- GitHub Actions에서 AI 리뷰 run이 실패했습니다.
- PR 코멘트가 생성되지 않았습니다.

## 수집한 에러

### Slack 알림 요약

```text
[AI Review] failed
PR: [add] review automation - AI 리뷰 워크플로우 및 Actions 초안 추가
Base: develop
Head: feature/ai_review_workflow
Findings: Blocker 0 / Major 0 / Minor 0 / Suggestion 0

### Overall Assessment
Response status code does not indicate success: 429 (Too Many Requests).
```

### GitHub Actions 로그

```text
RequestError [HttpError]: Resource not accessible by integration
status: 403
message: 'Resource not accessible by integration'
x-accepted-github-permissions: issues=write; pull_requests=write
documentation_url: 'https://docs.github.com/rest/issues/comments#create-an-issue-comment'
```

## 원인 분리

이번 실패는 하나의 원인이 아니라 아래 두 문제가 함께 발생한 경우로 판단합니다.

### 1. OpenAI API 호출 실패

- 응답 코드: `429 Too Many Requests`
- 의미:
  - rate limit 초과 가능성
  - 현재 quota 또는 billing 한도 문제 가능성
- 영향:
  - AI 리뷰 결과를 정상적으로 생성하지 못합니다.
  - workflow는 `failed` 상태 요약을 만들고 다음 단계로 넘어갑니다.

### 2. GitHub PR 코멘트 권한 부족

- 응답 코드: `403 Resource not accessible by integration`
- 로그의 `x-accepted-github-permissions`에 `issues=write; pull_requests=write`가 함께 표시되었습니다.
- 의미:
  - 현재 workflow token 권한으로는 PR 코멘트를 생성하거나 갱신할 수 없었습니다.
- 영향:
  - 실패 요약조차 PR 코멘트로 남기지 못합니다.
  - Actions run이 더 혼란스럽게 보일 수 있습니다.

## 판단 요령

AI 리뷰가 실패했을 때는 아래 순서로 분리해서 봅니다.

1. Slack 메시지나 Actions summary에서 OpenAI API 호출 실패가 있는지 확인합니다.
2. `Upsert pull request comment` step이 `403 Resource not accessible by integration`로 실패했는지 확인합니다.
3. 두 문제가 동시에 있을 수 있으므로 하나만 보고 결론내리지 않습니다.

## 이번에 적용한 수정

### workflow 권한 수정

`.github/workflows/ai_review.yml`에 아래 권한을 추가했습니다.

```yaml
permissions:
  contents: read
  issues: write
  pull-requests: write
```

이 수정의 목적은 `actions/github-script`가 PR 코멘트를 생성하거나 갱신할 수 있게 하는 것입니다.

### OpenAI 429 재시도 및 로그 개선

`invoke_ai_review.ps1`에 아래 동작을 추가했습니다.

- OpenAI Responses API 호출 시 `429`를 만나면 짧은 backoff 후 최대 3회 재시도
- 재시도 중 각 attempt를 Actions 로그에 출력
- 최종 실패 시 응답 코드뿐 아니라 가능한 경우 OpenAI 에러 body의 `type`, `code`, `message`까지 요약

이 수정의 목적은 단순히 `Too Many Requests`만 보이는 상태에서 벗어나, 실제 원인이 rate limit인지 quota/billing인지 더 빠르게 판단할 수 있게 하는 것입니다.

## 추가로 사람이 확인해야 하는 설정

코드 수정만으로 끝나지 않을 수 있으므로 저장소 설정도 함께 확인합니다.

### GitHub Actions workflow permissions

경로:

`Settings -> Actions -> General -> Workflow permissions`

확인 항목:

- `Read and write permissions`가 선택되어 있는지 확인합니다.

이 항목이 read-only면 workflow 파일에 권한을 적어도 실제 token 권한이 제한될 수 있습니다.

### OpenAI API quota / billing / limits

OpenAI Platform에서 아래를 확인합니다.

- API key가 올바른 프로젝트 또는 조직에 연결되어 있는지
- quota 또는 credit이 남아 있는지
- usage limit 또는 rate limit에 걸린 상태가 아닌지

## 재현 시 체크리스트

1. PR 대상 브랜치가 `develop`인지 확인합니다.
2. `OPENAI_API_KEY` Secret이 설정되어 있는지 확인합니다.
3. `SLACK_WEBHOOK_URL` Secret이 설정되어 있는지 확인합니다.
4. Actions run에서 `Run AI review` step과 `Upsert pull request comment` step을 각각 봅니다.
5. `429`와 `403`을 분리해서 판단합니다.
6. 필요하면 `Re-run jobs`로 다시 시도합니다.

## 후속 작업 제안

- PR 코멘트 실패와 AI 호출 실패를 summary에서 더 명확히 분리
- Notion 운영 문서에 "문제 발생 시 확인 경로" 섹션 추가
