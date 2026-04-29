$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptRoot\ai_orchestration_common.ps1"

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

$blockerCount = Get-IntFromEnv -Value $env:AI_REVIEW_BLOCKER_COUNT
$majorCount = Get-IntFromEnv -Value $env:AI_REVIEW_MAJOR_COUNT
$minorCount = Get-IntFromEnv -Value $env:AI_REVIEW_MINOR_COUNT
$suggestionCount = Get-IntFromEnv -Value $env:AI_REVIEW_SUGGESTION_COUNT
$sensitiveContentMasked = ($env:AI_REVIEW_SENSITIVE_CONTENT_MASKED -eq 'true')
$maskedContentTypes = [string]$env:AI_REVIEW_MASKED_CONTENT_TYPES
$shouldNotifySlack = $false

if ($env:AI_REVIEW_STATUS -eq 'failed') {
    $shouldNotifySlack = $true
}
elseif ($blockerCount -gt 0 -or $majorCount -gt 0) {
    $shouldNotifySlack = $true
}
elseif ($env:AI_REVIEW_SHOULD_NOTIFY_SLACK -eq 'true') {
    $shouldNotifySlack = $true
}

if (-not $shouldNotifySlack) {
    Write-Host '현재 AI 리뷰 결과는 Slack 알림 대상이 아닙니다.'
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
    $prTitleForSlack = if ($sensitiveContentMasked) { '민감정보 보호로 제목 생략' } else { $prTitle }

    $summaryText = ''
    if ($sensitiveContentMasked) {
        $summaryText = '민감정보로 보이는 문자열을 마스킹했기 때문에 이번 실행에서는 상세 요약을 Slack에 포함하지 않았습니다.'
        if (-not [string]::IsNullOrWhiteSpace($maskedContentTypes)) {
            $summaryText = "$summaryText`n마스킹 범주: $maskedContentTypes"
        }
    }
    elseif ($env:AI_REVIEW_COMMENT_PATH -and (Test-Path -LiteralPath $env:AI_REVIEW_COMMENT_PATH)) {
        $summaryText = Get-Content -LiteralPath $env:AI_REVIEW_COMMENT_PATH -Raw -Encoding utf8
        $summaryText = $summaryText -replace '\r', ''
        if ($summaryText.Length -gt 800) {
            $summaryText = $summaryText.Substring(0, 800)
        }
    }

    $localizedStatus = switch ([string]$env:AI_REVIEW_STATUS) {
        'completed' { '완료' }
        'failed' { '실패' }
        'skipped' { '건너뜀' }
        default { [string]$env:AI_REVIEW_STATUS }
    }

    $sensitiveMaskedLabel = if ($sensitiveContentMasked) { '적용' } else { '미적용' }

    $message = @"
[AI 리뷰] $localizedStatus
PR: $prTitleForSlack
기준 브랜치: $baseRef
작업 브랜치: $headRef
이슈 수: 차단 $blockerCount / 주요 $majorCount / 경미 $minorCount / 제안 $suggestionCount
민감정보 마스킹: $sensitiveMaskedLabel
링크: $prUrl

$summaryText
"@

    $maskedMessage = Protect-SensitiveText -Text ($message.Trim())
    $payload = @{
        text = [string]$maskedMessage.text
    }

    Invoke-RestMethod `
        -Method Post `
        -Uri $env:SLACK_WEBHOOK_URL `
        -ContentType 'application/json' `
        -Body ($payload | ConvertTo-Json -Depth 10) | Out-Null

    Write-Host 'Slack 알림을 전송했습니다.'
}
catch {
    Write-Warning "Slack 알림 전송에 실패했습니다: $($_.Exception.Message)"
}
