Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-IntFromEnv {
    param(
        [string]$Value
    )

    $parsedValue = 0
    if ([int]::TryParse($Value, [ref]$parsedValue)) {
        return $parsedValue
    }

    return 0
}

if ([string]::IsNullOrWhiteSpace($env:SLACK_WEBHOOK_URL)) {
    Write-Host 'SLACK_WEBHOOK_URL이 설정되지 않아 Slack 알림을 건너뜁니다.'
    exit 0
}

$blockerCount = Get-IntFromEnv -Value $env:ORCH_BLOCKER_COUNT
$majorCount = Get-IntFromEnv -Value $env:ORCH_MAJOR_COUNT
$minorCount = Get-IntFromEnv -Value $env:ORCH_MINOR_COUNT
$sensitiveContentMasked = ($env:ORCH_SENSITIVE_CONTENT_MASKED -eq 'true')
$maskedContentTypes = [string]$env:ORCH_MASKED_CONTENT_TYPES
$shouldNotifySlack = $false

if ($env:ORCH_REVIEW_STATUS -eq 'failed') {
    $shouldNotifySlack = $true
}
elseif ($env:ORCH_VERIFICATION_STATUS -eq 'failed') {
    $shouldNotifySlack = $true
}
elseif ($env:ORCH_HUMAN_GATE_REQUIRED -eq 'true') {
    $shouldNotifySlack = $true
}
elseif ($env:ORCH_SHOULD_NOTIFY_SLACK -eq 'true') {
    $shouldNotifySlack = $true
}

if (-not $shouldNotifySlack) {
    Write-Host '현재 AI 오케스트레이션 결과는 Slack 알림 대상이 아닙니다.'
    exit 0
}

try {
    $event = $null
    if ($env:GITHUB_EVENT_PATH -and (Test-Path -LiteralPath $env:GITHUB_EVENT_PATH)) {
        $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw -Encoding utf8 | ConvertFrom-Json
    }

    $pr = $null
    if ($null -ne $event -and $null -ne $event.pull_request) {
        $pr = $event.pull_request
    }

    $prTitle = if ($null -ne $pr) { [string]$pr.title } else { [string]$env:GITHUB_REPOSITORY }
    $prUrl = if ($null -ne $pr) { [string]$pr.html_url } else { "https://github.com/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)" }
    $baseRef = if ($null -ne $pr) { [string]$pr.base.ref } else { [string]$env:AI_REVIEW_BASE_REF }
    $headRef = if ($null -ne $pr) { [string]$pr.head.ref } else { [string]$env:GITHUB_REF_NAME }

    $summaryText = ''
    if ($sensitiveContentMasked) {
        $summaryText = 'Sensitive-looking strings were masked before AI orchestration. Slack intentionally omits the detailed summary for this run.'
        if (-not [string]::IsNullOrWhiteSpace($maskedContentTypes)) {
            $summaryText = "$summaryText`nMasked categories: $maskedContentTypes"
        }
    }
    elseif ($env:ORCH_COMMENT_PATH -and (Test-Path -LiteralPath $env:ORCH_COMMENT_PATH)) {
        $summaryText = Get-Content -LiteralPath $env:ORCH_COMMENT_PATH -Raw -Encoding utf8
        $summaryText = $summaryText -replace '\r', ''
        if ($summaryText.Length -gt 1000) {
            $summaryText = $summaryText.Substring(0, 1000)
        }
    }

    $sensitiveMaskedLabel = 'no'
    if ($sensitiveContentMasked) {
        $sensitiveMaskedLabel = 'yes'
    }

    $message = @"
[AI 오케스트레이션] $($env:ORCH_FINAL_DECISION)
PR: $prTitle
기준 브랜치: $baseRef
작업 브랜치: $headRef
검증 상태: $($env:ORCH_VERIFICATION_STATUS)
Human Gate: $($env:ORCH_HUMAN_GATE_REQUIRED)
이슈 수: 차단 $blockerCount / 주요 $majorCount / 경미 $minorCount / 제안 $($env:ORCH_SUGGESTION_COUNT)
민감정보 마스킹: $sensitiveMaskedLabel
링크: $prUrl

$summaryText
"@

    $payload = @{
        text = $message.Trim()
    }

    Invoke-RestMethod `
        -Method Post `
        -Uri $env:SLACK_WEBHOOK_URL `
        -ContentType 'application/json' `
        -Body ($payload | ConvertTo-Json -Depth 10) | Out-Null

    Write-Host 'AI 오케스트레이션 Slack 알림을 전송했습니다.'
}
catch {
    Write-Warning "AI 오케스트레이션 Slack 알림 전송에 실패했습니다: $($_.Exception.Message)"
}
