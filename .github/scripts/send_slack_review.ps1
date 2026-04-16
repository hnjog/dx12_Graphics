Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:SLACK_WEBHOOK_URL)) {
    Write-Host 'SLACK_WEBHOOK_URL is not configured. Skipping Slack notification.'
    exit 0
}

if ($env:AI_REVIEW_SHOULD_NOTIFY_SLACK -ne 'true') {
    Write-Host 'AI review result does not require Slack notification.'
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
    if ($env:AI_REVIEW_COMMENT_PATH -and (Test-Path -LiteralPath $env:AI_REVIEW_COMMENT_PATH)) {
        $summaryText = Get-Content -LiteralPath $env:AI_REVIEW_COMMENT_PATH -Raw -Encoding utf8
        $summaryText = $summaryText -replace '\r', ''
        if ($summaryText.Length -gt 800) {
            $summaryText = $summaryText.Substring(0, 800)
        }
    }

    $message = @"
[AI Review] $($env:AI_REVIEW_STATUS)
PR: $prTitle
Base: $baseRef
Head: $headRef
Findings: Blocker $($env:AI_REVIEW_BLOCKER_COUNT) / Major $($env:AI_REVIEW_MAJOR_COUNT) / Minor $($env:AI_REVIEW_MINOR_COUNT) / Suggestion $($env:AI_REVIEW_SUGGESTION_COUNT)
Link: $prUrl

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

    Write-Host 'Slack notification sent.'
}
catch {
    Write-Warning "Slack notification failed: $($_.Exception.Message)"
}
