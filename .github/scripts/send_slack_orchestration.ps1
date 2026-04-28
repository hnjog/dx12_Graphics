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
    Write-Host 'SLACK_WEBHOOK_URL???ㅼ젙?섏? ?딆븘 Slack ?뚮┝??嫄대꼫?곷땲??'
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
    Write-Host '?꾩옱 AI ?ㅼ??ㅽ듃?덉씠??寃곌낵??Slack ?뚮┝ ??곸씠 ?꾨떃?덈떎.'
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
        $summaryText = '誘쇨컧?뺣낫濡?蹂댁씠??臾몄옄?댁쓣 留덉뒪?뱁뻽湲??뚮Ц???대쾲 ?ㅽ뻾?먯꽌???곸꽭 ?붿빟??Slack???ы븿?섏? ?딆븯?듬땲??'
        if (-not [string]::IsNullOrWhiteSpace($maskedContentTypes)) {
            $summaryText = "$summaryText`n留덉뒪??踰붿＜: $maskedContentTypes"
        }
    }
    elseif ($env:ORCH_COMMENT_PATH -and (Test-Path -LiteralPath $env:ORCH_COMMENT_PATH)) {
        $summaryText = Get-Content -LiteralPath $env:ORCH_COMMENT_PATH -Raw -Encoding utf8
        $summaryText = $summaryText -replace '\r', ''
        if ($summaryText.Length -gt 1000) {
            $summaryText = $summaryText.Substring(0, 1000)
        }
    }

    $localizedDecision = switch ([string]$env:ORCH_FINAL_DECISION) {
        'pass' { '?듦낵' }
        'needs_human' { '?щ엺 寃???꾩슂' }
        'failed' { '?ㅽ뙣' }
        default { [string]$env:ORCH_FINAL_DECISION }
    }

    $localizedVerificationStatus = switch ([string]$env:ORCH_VERIFICATION_STATUS) {
        'passed' { '?듦낵' }
        'failed' { '?ㅽ뙣' }
        'skipped' { '嫄대꼫?' }
        default { [string]$env:ORCH_VERIFICATION_STATUS }
    }

    $humanGateLabel = if ($env:ORCH_HUMAN_GATE_REQUIRED -eq 'true') { "필요" } else { "불필요" }
    $sensitiveMaskedLabel = if ($sensitiveContentMasked) { "적용" } else { "미적용" }

    $message = @"
[AI ?ㅼ??ㅽ듃?덉씠?? $localizedDecision
PR: $prTitle
湲곗? 釉뚮옖移? $baseRef
?묒뾽 釉뚮옖移? $headRef
寃利??곹깭: $localizedVerificationStatus
Human Gate: $humanGateLabel
?댁뒋 ?? 李⑤떒 $blockerCount / 二쇱슂 $majorCount / 寃쎈? $minorCount / ?쒖븞 $($env:ORCH_SUGGESTION_COUNT)
誘쇨컧?뺣낫 留덉뒪?? $sensitiveMaskedLabel
留곹겕: $prUrl

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

    Write-Host 'AI ?ㅼ??ㅽ듃?덉씠??Slack ?뚮┝???꾩넚?덉뒿?덈떎.'
}
catch {
    Write-Warning "AI ?ㅼ??ㅽ듃?덉씠??Slack ?뚮┝ ?꾩넚???ㅽ뙣?덉뒿?덈떎: $($_.Exception.Message)"
}
