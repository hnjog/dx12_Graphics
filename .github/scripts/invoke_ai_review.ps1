Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\ai_orchestration_common.ps1"

function Set-WorkflowOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if ($env:GITHUB_OUTPUT) {
        Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value"
    }
}

function Get-ResponseText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response
    )

    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($message in @($Response.output)) {
        if ($null -eq $message -or $message.type -ne 'message') {
            continue
        }

        foreach ($content in @($message.content)) {
            if ($null -ne $content -and $content.type -eq 'output_text' -and $content.text) {
                $texts.Add([string]$content.text)
            }
        }
    }

    return ($texts -join "`n")
}

function Get-HttpStatusCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    if ($null -ne $Exception.PSObject.Properties['Response'] -and $null -ne $Exception.Response) {
        $statusCode = $Exception.Response.StatusCode
        if ($statusCode -is [int]) {
            return [int]$statusCode
        }

        if ($null -ne $statusCode) {
            return [int]$statusCode.value__
        }
    }

    return $null
}

function Get-HttpResponseBody {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    if (
        $null -ne $Exception.PSObject.Properties['ErrorDetails'] -and
        $null -ne $Exception.ErrorDetails -and
        -not [string]::IsNullOrWhiteSpace([string]$Exception.ErrorDetails.Message)
    ) {
        return [string]$Exception.ErrorDetails.Message
    }

    if ($null -ne $Exception.PSObject.Properties['Response'] -and $null -ne $Exception.Response -and $null -ne $Exception.Response.Content) {
        try {
            return $Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        }
        catch {
            return ''
        }
    }

    return ''
}

function Get-OpenAIErrorDetail {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $statusCode = Get-HttpStatusCode -Exception $Exception
    $body = Get-HttpResponseBody -Exception $Exception

    if ([string]::IsNullOrWhiteSpace($body)) {
        if ($null -ne $statusCode) {
            return "HTTP $statusCode. $($Exception.Message)"
        }

        return $Exception.Message
    }

    try {
        $parsed = $body | ConvertFrom-Json
        if ($null -ne $parsed.error) {
            $message = [string]$parsed.error.message
            $type = [string]$parsed.error.type
            $code = [string]$parsed.error.code
            $parts = New-Object System.Collections.Generic.List[string]

            if ($null -ne $statusCode) {
                $parts.Add("HTTP $statusCode")
            }

            if (-not [string]::IsNullOrWhiteSpace($type)) {
                $parts.Add("type=$type")
            }

            if (-not [string]::IsNullOrWhiteSpace($code)) {
                $parts.Add("code=$code")
            }

            if (-not [string]::IsNullOrWhiteSpace($message)) {
                $parts.Add("message=$message")
            }

            return ($parts -join ', ')
        }
    }
    catch {
        # Fall back to the raw body below.
    }

    if ($null -ne $statusCode) {
        return "HTTP $statusCode. Response body: $body"
    }

    return "Response body: $body"
}

function Test-IsTimeoutException {
    param(
        [Parameter(Mandatory = $true)]
        [System.Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        $typeName = [string]$current.GetType().FullName
        $message = [string]$current.Message

        if (
            $typeName -match 'TimeoutException|TaskCanceledException|OperationCanceledException' -or
            $message -match 'timed out|timeout|request was canceled|operation was canceled|HttpClient\.Timeout'
        ) {
            return $true
        }

        $current = $current.InnerException
    }

    return $false
}

function Invoke-OpenAIResponsesRequest {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,
        [Parameter(Mandatory = $true)]
        [hashtable]$Body,
        [int]$MaxAttempts = 3,
        [int]$TimeoutSeconds = 90
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-Host "OpenAI Responses API request attempt $attempt/$MaxAttempts (timeout ${TimeoutSeconds}s)"

            $response = Invoke-RestMethod `
                -Method Post `
                -Uri 'https://api.openai.com/v1/responses' `
                -Headers $Headers `
                -Body ($Body | ConvertTo-Json -Depth 100) `
                -TimeoutSec $TimeoutSeconds

            Write-Host "OpenAI Responses API request succeeded on attempt $attempt/$MaxAttempts"
            return $response
        }
        catch {
            $statusCode = Get-HttpStatusCode -Exception $_.Exception
            try {
                $detail = Get-OpenAIErrorDetail -Exception $_.Exception
            }
            catch {
                $detail = "Failed to inspect the original exception detail. Fallback message: $($_.Exception.Message)"
            }
            $isTimeout = Test-IsTimeoutException -Exception $_.Exception

            if (($statusCode -eq 429 -or $isTimeout) -and $attempt -lt $MaxAttempts) {
                $delaySeconds = [Math]::Min(20, [int][Math]::Pow(2, $attempt))

                if ($statusCode -eq 429) {
                    Write-Warning "OpenAI request hit HTTP 429 on attempt $attempt/$MaxAttempts. Retrying in $delaySeconds seconds. Detail: $detail"
                }
                elseif ($isTimeout) {
                    Write-Warning "OpenAI request timed out on attempt $attempt/$MaxAttempts. Retrying in $delaySeconds seconds. Detail: $detail"
                }

                Start-Sleep -Seconds $delaySeconds
                continue
            }

            if ($statusCode -eq 429) {
                throw "OpenAI Responses API failed after $MaxAttempts attempts. $detail"
            }

            if ($isTimeout) {
                throw "OpenAI Responses API request timed out after $MaxAttempts attempts with timeout ${TimeoutSeconds}s. $detail"
            }

            throw "OpenAI Responses API request failed. $detail"
        }
    }

    throw "OpenAI Responses API request failed without returning a response."
}

function New-ReviewObject {
    param(
        [string]$Summary,
        [string]$OverallAssessment,
        [string]$RiskLevel,
        [array]$Findings,
        [bool]$ShouldNotifySlack,
        [string]$SlackReason
    )

    return [pscustomobject]@{
        summary              = $Summary
        overall_assessment   = $OverallAssessment
        risk_level           = $RiskLevel
        findings             = $Findings
        should_notify_slack  = $ShouldNotifySlack
        slack_reason         = $SlackReason
    }
}

function Get-LocalizedStatusLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    switch ($Status) {
        'completed' { return '완료' }
        'failed' { return '실패' }
        'skipped' { return '건너뜀' }
        default { return $Status }
    }
}

function Get-LocalizedRiskLevel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RiskLevel
    )

    switch ($RiskLevel) {
        'low' { return '낮음' }
        'medium' { return '보통' }
        'high' { return '높음' }
        'unknown' { return '알 수 없음' }
        default { return $RiskLevel }
    }
}

function Get-LocalizedSeverity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Severity
    )

    switch ($Severity) {
        'Blocker' { return '차단' }
        'Major' { return '주요' }
        'Minor' { return '경미' }
        'Suggestion' { return '제안' }
        default { return $Severity }
    }
}

function Get-BoundedText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [int]$MaxLength,
        [string]$Label = 'text'
    )

    if ($MaxLength -le 0 -or [string]::IsNullOrEmpty($Text) -or $Text.Length -le $MaxLength) {
        return $Text
    }

    return $Text.Substring(0, $MaxLength) + "`n`n[Truncated $Label to first $MaxLength characters.]"
}

function Get-ReviewFilePlan {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths
    )

    $plans = foreach ($path in $Paths) {
        $normalizedPath = ([string]$path).Replace('\', '/').ToLowerInvariant()
        $extension = [System.IO.Path]::GetExtension($normalizedPath).ToLowerInvariant()
        $score = 0
        $contextLines = 1
        $priorityLabel = 'low'

        if ($extension -in @('.cpp', '.c', '.cc', '.h', '.hpp', '.hxx', '.inl', '.hlsl', '.hlsli')) {
            $score += 60
            $contextLines = 2
            $priorityLabel = 'medium'
        }
        elseif ($extension -in @('.ps1', '.yml', '.yaml', '.json', '.vcxproj', '.filters', '.props', '.targets')) {
            $score += 35
            $contextLines = 2
            $priorityLabel = 'medium'
        }
        elseif ($extension -eq '.md') {
            $score += 10
        }

        if (
            $normalizedPath -match 'dx12|renderer|rendering|mesh|shader|rootsignature|root-signature|descriptor|swapchain|command|fence|resource|platform/win32' -or
            $normalizedPath -match '^dx12engine/source/'
        ) {
            $score += 120
            $contextLines = 3
            $priorityLabel = 'high'
        }
        elseif ($normalizedPath -match 'source/|app/|platform/|scripts/|workflows/') {
            $score += 40
            $contextLines = [Math]::Max($contextLines, 2)
            if ($priorityLabel -ne 'high') {
                $priorityLabel = 'medium'
            }
        }

        if ($normalizedPath -match '^docs/' -or $extension -eq '.md') {
            $score -= 15
        }

        [pscustomobject]@{
            path          = $path
            score         = $score
            context_lines = $contextLines
            priority      = $priorityLabel
        }
    }

    return @(
        $plans |
            Sort-Object `
                -Property `
                    @{ Expression = { [int]$_.score }; Descending = $true }, `
                    @{ Expression = { [string]$_.path }; Descending = $false }
    )
}

function Get-BoundedDiffByFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CompareRange,
        [Parameter(Mandatory = $true)]
        [object[]]$FilePlans,
        [Parameter(Mandatory = $true)]
        [int]$MaxLength
    )

    $sections = New-Object System.Collections.Generic.List[string]
    $includedFileCount = 0
    $truncatedFilePath = ''
    $remainingFileCount = 0

    foreach ($plan in $FilePlans) {
        $filePath = [string]$plan.path
        $contextLines = [int]$plan.context_lines
        $priorityLabel = [string]$plan.priority

        $fileDiff = (& git diff "--unified=$contextLines" --no-color $CompareRange -- $filePath) | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to collect diff for file $filePath in compare range $CompareRange."
        }

        if ([string]::IsNullOrWhiteSpace($fileDiff)) {
            continue
        }

        $section = @"
### FILE: $filePath (priority=$priorityLabel, unified=$contextLines)
$($fileDiff.TrimEnd())

"@

        $currentLength = ($sections -join '').Length
        $remainingLength = $MaxLength - $currentLength
        if ($remainingLength -le 0) {
            $truncatedFilePath = $filePath
            break
        }

        if ($section.Length -le $remainingLength) {
            $sections.Add($section)
            $includedFileCount++
            continue
        }

        $prefix = "### FILE: $filePath (priority=$priorityLabel, unified=$contextLines)`n"
        $availableForBody = $remainingLength - $prefix.Length - 48
        if ($availableForBody -gt 0) {
            $trimmedBody = $fileDiff.TrimEnd()
            if ($trimmedBody.Length -gt $availableForBody) {
                $trimmedBody = $trimmedBody.Substring(0, $availableForBody)
            }

            $sections.Add($prefix + $trimmedBody + "`n[Diff truncated for this file]`n")
        }

        $includedFileCount++
        $truncatedFilePath = $filePath
        break
    }

    if ($includedFileCount -lt $FilePlans.Count) {
        $remainingFileCount = $FilePlans.Count - $includedFileCount
    }

    return [pscustomobject]@{
        text                 = ($sections -join '')
        included_file_count  = $includedFileCount
        remaining_file_count = $remainingFileCount
        truncated_file_path  = $truncatedFilePath
    }
}

function Write-ReviewMarkdown {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$BaseRef,
        [Parameter(Mandatory = $true)]
        [object]$Review,
        [string]$DiffNote,
        [bool]$SensitiveContentMasked = $false,
        [string[]]$MaskedContentTypes = @()
    )

    $findings = @($Review.findings)
    $blockerCount = @($findings | Where-Object { $_.severity -eq 'Blocker' }).Count
    $majorCount = @($findings | Where-Object { $_.severity -eq 'Major' }).Count
    $minorCount = @($findings | Where-Object { $_.severity -eq 'Minor' }).Count
    $suggestionCount = @($findings | Where-Object { $_.severity -eq 'Suggestion' }).Count

    $localizedStatus = Get-LocalizedStatusLabel -Status $Status
    $localizedRiskLevel = Get-LocalizedRiskLevel -RiskLevel ([string]$Review.risk_level)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('## AI 리뷰')
    $lines.Add('')
    $lines.Add("- 상태: $localizedStatus")
    $lines.Add("- 모델: $Model")
    $lines.Add("- 기준 브랜치: $BaseRef")
    $lines.Add("- 위험도: $localizedRiskLevel")
    $lines.Add("- 이슈 수: 차단 $blockerCount / 주요 $majorCount / 경미 $minorCount / 제안 $suggestionCount")
    if ($SensitiveContentMasked) {
        $maskedTypesLabel = if (@($MaskedContentTypes).Count -gt 0) { " ($($MaskedContentTypes -join ', '))" } else { '' }
        $lines.Add("- 민감정보 마스킹: 적용됨$maskedTypesLabel")
    }
    $lines.Add('')
    $lines.Add('### 요약')
    $lines.Add($Review.summary)
    $lines.Add('')
    $lines.Add('### 종합 판단')
    $lines.Add($Review.overall_assessment)
    $lines.Add('')
    $lines.Add('### 세부 이슈')

    if ($findings.Count -eq 0) {
        $lines.Add('- AI 리뷰에서 보고된 이슈가 없습니다.')
    }
    else {
        $index = 1
        foreach ($finding in $findings) {
            $location = [string]$finding.file
            if ([int]$finding.line_start -gt 0) {
                $location = "${location}:$($finding.line_start)"
            }

            $localizedSeverity = Get-LocalizedSeverity -Severity ([string]$finding.severity)

            $lines.Add("$index. [$localizedSeverity] $($finding.title)")
            $lines.Add('   - 위치: `' + $location + '`')
            $lines.Add("   - 위험: $($finding.risk)")
            $lines.Add("   - 권장 대응: $($finding.recommendation)")
            $lines.Add("   - 신뢰도: $($finding.confidence)")
            $index++
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DiffNote)) {
        $lines.Add('')
        $lines.Add("> $DiffNote")
    }

    $markdownText = $lines -join "`n"
    $maskedMarkdown = Protect-SensitiveText -Text $markdownText
    Set-Content -Path $Path -Value ([string]$maskedMarkdown.text) -Encoding utf8
}

$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { (Get-Location).Path }
$commentPath = Join-Path $tempRoot 'ai-review-comment.md'
$summaryPath = Join-Path $tempRoot 'ai-review-summary.md'

$baseRef = $env:AI_REVIEW_BASE_REF
if ([string]::IsNullOrWhiteSpace($baseRef)) {
    $baseRef = 'develop'
}

$model = $env:OPENAI_MODEL
if ([string]::IsNullOrWhiteSpace($model)) {
    $model = 'gpt-5.4-mini'
}

$requestTimeoutSeconds = 90
if (-not [string]::IsNullOrWhiteSpace($env:OPENAI_TIMEOUT_SECONDS)) {
    $parsedTimeoutSeconds = 0
    if ([int]::TryParse($env:OPENAI_TIMEOUT_SECONDS, [ref]$parsedTimeoutSeconds) -and $parsedTimeoutSeconds -gt 0) {
        $requestTimeoutSeconds = $parsedTimeoutSeconds
    }
}

$event = $null
$sensitiveContentMasked = $false
$maskedLabels = @()
if ($env:GITHUB_EVENT_PATH -and (Test-Path -LiteralPath $env:GITHUB_EVENT_PATH)) {
    $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw -Encoding utf8 | ConvertFrom-Json
}

$pr = $null
if ($null -ne $event -and $null -ne $event.pull_request) {
    $pr = $event.pull_request
    if (-not [string]::IsNullOrWhiteSpace([string]$pr.base.ref)) {
        $baseRef = [string]$pr.base.ref
    }
}

$diffNote = ''

try {
    $reviewRules = Get-Content -LiteralPath 'docs/review-rules.md' -Raw -Encoding utf8
    $testingStrategy = Get-Content -LiteralPath 'docs/testing-strategy.md' -Raw -Encoding utf8

    if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        $review = New-ReviewObject `
            -Summary 'OPENAI_API_KEY secret이 설정되지 않아 AI 리뷰를 건너뛰었습니다.' `
            -OverallAssessment '저장소 secret을 설정한 뒤 workflow를 다시 실행해야 AI 리뷰 결과를 신뢰할 수 있습니다.' `
            -RiskLevel 'unknown' `
            -Findings @() `
            -ShouldNotifySlack $false `
            -SlackReason 'missing_openai_api_key'

        Write-ReviewMarkdown -Path $commentPath -Status 'skipped' -Model $model -BaseRef $baseRef -Review $review -DiffNote $diffNote -SensitiveContentMasked $sensitiveContentMasked -MaskedContentTypes $maskedLabels
        Write-ReviewMarkdown -Path $summaryPath -Status 'skipped' -Model $model -BaseRef $baseRef -Review $review -DiffNote $diffNote -SensitiveContentMasked $sensitiveContentMasked -MaskedContentTypes $maskedLabels
        Get-Content -LiteralPath $summaryPath -Raw | Add-Content -Path $env:GITHUB_STEP_SUMMARY

        Set-WorkflowOutput -Name 'review_status' -Value 'skipped'
        Set-WorkflowOutput -Name 'comment_path' -Value $commentPath
        Set-WorkflowOutput -Name 'summary_path' -Value $summaryPath
        Set-WorkflowOutput -Name 'blocker_count' -Value '0'
        Set-WorkflowOutput -Name 'major_count' -Value '0'
        Set-WorkflowOutput -Name 'minor_count' -Value '0'
        Set-WorkflowOutput -Name 'suggestion_count' -Value '0'
        Set-WorkflowOutput -Name 'should_notify_slack' -Value 'false'
        Set-WorkflowOutput -Name 'sensitive_content_masked' -Value ($sensitiveContentMasked.ToString().ToLowerInvariant())
        Set-WorkflowOutput -Name 'masked_content_types' -Value ($maskedLabels -join ',')
        Set-WorkflowOutput -Name 'model_used' -Value $model
        exit 0
    }

    $null = git fetch --no-tags --depth=1 origin $baseRef
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to fetch origin/$baseRef for AI review context."
    }

    $compareRange = "origin/$baseRef...HEAD"
    $changedFiles = @(git diff --name-only $compareRange)
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to collect changed files for compare range $compareRange."
    }

    if ($changedFiles.Count -eq 0) {
        $review = New-ReviewObject `
            -Summary '현재 compare range에서 파일 diff를 찾지 못해 AI 리뷰 이슈를 보고하지 않았습니다.' `
            -OverallAssessment '예상과 다르다면 PR 대상 브랜치를 확인한 뒤 workflow를 다시 실행해 주세요.' `
            -RiskLevel 'low' `
            -Findings @() `
            -ShouldNotifySlack $false `
            -SlackReason 'no_diff'

        Write-ReviewMarkdown -Path $commentPath -Status 'skipped' -Model $model -BaseRef $baseRef -Review $review -DiffNote $diffNote -SensitiveContentMasked $sensitiveContentMasked -MaskedContentTypes $maskedLabels
        Write-ReviewMarkdown -Path $summaryPath -Status 'skipped' -Model $model -BaseRef $baseRef -Review $review -DiffNote $diffNote -SensitiveContentMasked $sensitiveContentMasked -MaskedContentTypes $maskedLabels
        Get-Content -LiteralPath $summaryPath -Raw | Add-Content -Path $env:GITHUB_STEP_SUMMARY

        Set-WorkflowOutput -Name 'review_status' -Value 'skipped'
        Set-WorkflowOutput -Name 'comment_path' -Value $commentPath
        Set-WorkflowOutput -Name 'summary_path' -Value $summaryPath
        Set-WorkflowOutput -Name 'blocker_count' -Value '0'
        Set-WorkflowOutput -Name 'major_count' -Value '0'
        Set-WorkflowOutput -Name 'minor_count' -Value '0'
        Set-WorkflowOutput -Name 'suggestion_count' -Value '0'
        Set-WorkflowOutput -Name 'should_notify_slack' -Value 'false'
        Set-WorkflowOutput -Name 'sensitive_content_masked' -Value ($sensitiveContentMasked.ToString().ToLowerInvariant())
        Set-WorkflowOutput -Name 'masked_content_types' -Value ($maskedLabels -join ',')
        Set-WorkflowOutput -Name 'model_used' -Value $model
        exit 0
    }

    $prTitle = if ($null -ne $pr) { [string]$pr.title } else { '' }
    $prBody = if ($null -ne $pr) { [string]$pr.body } else { '' }
    $prUrl = if ($null -ne $pr) { [string]$pr.html_url } else { '' }
    $headRef = if ($null -ne $pr) { [string]$pr.head.ref } else { [string]$env:GITHUB_REF_NAME }
    $filePlans = Get-ReviewFilePlan -Paths $changedFiles
    $diffBundle = Get-BoundedDiffByFile -CompareRange $compareRange -FilePlans $filePlans -MaxLength 60000
    $diffText = [string]$diffBundle.text
    if ([string]::IsNullOrWhiteSpace($diffText)) {
        throw "Failed to build prioritized diff text for compare range $compareRange."
    }

    if ($diffBundle.remaining_file_count -gt 0) {
        $diffNote = "AI 리뷰 요청 길이를 제한하기 위해 중요도가 높은 파일 순으로 diff를 구성했습니다. 포함 파일 수: $($diffBundle.included_file_count), 제외 파일 수: $($diffBundle.remaining_file_count), 마지막 절단 파일: $($diffBundle.truncated_file_path)"
    }

    $reviewRulesForPrompt = Get-BoundedText -Text $reviewRules -MaxLength 4500 -Label 'review rules'
    $testingStrategyForPrompt = Get-BoundedText -Text $testingStrategy -MaxLength 3500 -Label 'testing strategy'
    $prBodyForPrompt = Get-BoundedText -Text $prBody -MaxLength 5000 -Label 'pull request body'
    $changedFilesForPrompt = @($filePlans.path | Select-Object -First 80)
    $changedFilesNote = ''
    if ($changedFiles.Count -gt $changedFilesForPrompt.Count) {
        $changedFilesNote = "Changed files list was sorted by review priority and truncated to the first $($changedFilesForPrompt.Count) entries."
    }

    $maskedPrTitle = Protect-SensitiveText -Text $prTitle
    $maskedPrBody = Protect-SensitiveText -Text $prBodyForPrompt
    $maskedDiffText = Protect-SensitiveText -Text $diffText
    $maskedReviewRules = Protect-SensitiveText -Text $reviewRulesForPrompt
    $maskedTestingStrategy = Protect-SensitiveText -Text $testingStrategyForPrompt

    $maskedFragments = @(
        $maskedPrTitle,
        $maskedPrBody,
        $maskedDiffText,
        $maskedReviewRules,
        $maskedTestingStrategy
    )

    $prTitle = [string]$maskedFragments[0].text
    $prBodyForPrompt = [string]$maskedFragments[1].text
    $diffText = [string]$maskedFragments[2].text
    $reviewRulesForPrompt = [string]$maskedFragments[3].text
    $testingStrategyForPrompt = [string]$maskedFragments[4].text

    $maskedLabels = @()
    foreach ($fragment in $maskedFragments) {
        if ($fragment.has_sensitive_content) {
            $maskedLabels += @($fragment.labels)
        }
    }

    if ($maskedLabels.Count -gt 0) {
        $maskedLabels = @($maskedLabels | Select-Object -Unique)
        $sensitiveContentMasked = $true
        if ([string]::IsNullOrWhiteSpace($diffNote)) {
            $diffNote = "AI 리뷰 입력으로 전달되기 전에 민감정보로 보이는 문자열을 마스킹했습니다. 범주: $($maskedLabels -join ', ')."
        }
        else {
            $diffNote = "$diffNote`nAI 리뷰 입력으로 전달되기 전에 민감정보로 보이는 문자열을 마스킹했습니다. 범주: $($maskedLabels -join ', ')."
        }
    }

    $instructions = @"
You are reviewing a pull request for the dx12_Graphics repository.
Prioritize correctness, regressions, DirectX 12 resource lifetime, synchronization, state transitions, API misuse, and missing verification over style comments.
Only raise findings that materially matter to the repository's stated review rules.
If a concern depends on an assumption, say so in the finding instead of stating it as a fact.
Return at most 8 findings.
Write all user-facing prose in Korean.
Keep enum values exactly as specified in the schema.
Keep slack_reason as a short snake_case English identifier.
"@

    $userPrompt = @"
Repository review rules (excerpt):
$reviewRulesForPrompt

Repository testing strategy (excerpt):
$testingStrategyForPrompt

Pull request metadata:
- Title: $prTitle
- URL: $prUrl
- Base branch: $baseRef
- Head branch: $headRef

Pull request body:
$prBodyForPrompt

Changed files:
$($changedFilesForPrompt -join "`n")

$changedFilesNote

Unified diff:
$diffText
"@

    $schema = @{
        type                 = 'object'
        additionalProperties = $false
        properties           = @{
            summary             = @{ type = 'string' }
            overall_assessment  = @{ type = 'string' }
            risk_level          = @{ type = 'string'; enum = @('low', 'medium', 'high', 'unknown') }
            findings            = @{
                type  = 'array'
                items = @{
                    type                 = 'object'
                    additionalProperties = $false
                    properties           = @{
                        severity       = @{ type = 'string'; enum = @('Blocker', 'Major', 'Minor', 'Suggestion') }
                        title          = @{ type = 'string' }
                        file           = @{ type = 'string' }
                        line_start     = @{ type = 'integer'; minimum = 0 }
                        line_end       = @{ type = 'integer'; minimum = 0 }
                        risk           = @{ type = 'string' }
                        recommendation = @{ type = 'string' }
                        confidence     = @{ type = 'number'; minimum = 0; maximum = 1 }
                    }
                    required             = @('severity', 'title', 'file', 'line_start', 'line_end', 'risk', 'recommendation', 'confidence')
                }
            }
            should_notify_slack = @{ type = 'boolean' }
            slack_reason        = @{ type = 'string' }
        }
        required             = @('summary', 'overall_assessment', 'risk_level', 'findings', 'should_notify_slack', 'slack_reason')
    }

    $body = @{
        model       = $model
        instructions = $instructions
        input       = $userPrompt
        reasoning   = @{
            effort = 'low'
        }
        text        = @{
            format = @{
                type   = 'json_schema'
                name   = 'ai_review_result'
                strict = $true
                schema = $schema
            }
        }
    }

    $headers = @{
        Authorization = "Bearer $($env:OPENAI_API_KEY)"
        'Content-Type' = 'application/json'
    }

    $response = Invoke-OpenAIResponsesRequest -Headers $headers -Body $body -TimeoutSeconds $requestTimeoutSeconds

    $rawText = Get-ResponseText -Response $response
    if ([string]::IsNullOrWhiteSpace($rawText)) {
        throw 'OpenAI response did not contain output_text content.'
    }

    $review = $rawText | ConvertFrom-Json

    Write-ReviewMarkdown -Path $commentPath -Status 'completed' -Model $model -BaseRef $baseRef -Review $review -DiffNote $diffNote -SensitiveContentMasked $sensitiveContentMasked -MaskedContentTypes $maskedLabels
    Write-ReviewMarkdown -Path $summaryPath -Status 'completed' -Model $model -BaseRef $baseRef -Review $review -DiffNote $diffNote -SensitiveContentMasked $sensitiveContentMasked -MaskedContentTypes $maskedLabels
    Get-Content -LiteralPath $summaryPath -Raw | Add-Content -Path $env:GITHUB_STEP_SUMMARY

    $findings = @($review.findings)
    $blockerCount = @($findings | Where-Object { $_.severity -eq 'Blocker' }).Count
    $majorCount = @($findings | Where-Object { $_.severity -eq 'Major' }).Count
    $minorCount = @($findings | Where-Object { $_.severity -eq 'Minor' }).Count
    $suggestionCount = @($findings | Where-Object { $_.severity -eq 'Suggestion' }).Count

    Set-WorkflowOutput -Name 'review_status' -Value 'completed'
    Set-WorkflowOutput -Name 'comment_path' -Value $commentPath
    Set-WorkflowOutput -Name 'summary_path' -Value $summaryPath
    Set-WorkflowOutput -Name 'blocker_count' -Value ([string]$blockerCount)
    Set-WorkflowOutput -Name 'major_count' -Value ([string]$majorCount)
    Set-WorkflowOutput -Name 'minor_count' -Value ([string]$minorCount)
    Set-WorkflowOutput -Name 'suggestion_count' -Value ([string]$suggestionCount)
    Set-WorkflowOutput -Name 'should_notify_slack' -Value (([bool]$review.should_notify_slack).ToString().ToLowerInvariant())
    Set-WorkflowOutput -Name 'sensitive_content_masked' -Value ($sensitiveContentMasked.ToString().ToLowerInvariant())
    Set-WorkflowOutput -Name 'masked_content_types' -Value ($maskedLabels -join ',')
    Set-WorkflowOutput -Name 'model_used' -Value $model
}
catch {
    Write-Error "AI review failed: $($_.Exception.Message)"

    $review = New-ReviewObject `
        -Summary '사용 가능한 리뷰 결과를 만들기 전에 AI 리뷰 실행이 실패했습니다.' `
        -OverallAssessment "실패 원인: $($_.Exception.Message)" `
        -RiskLevel 'unknown' `
        -Findings @() `
        -ShouldNotifySlack $true `
        -SlackReason 'workflow_failed'

    Write-ReviewMarkdown -Path $commentPath -Status 'failed' -Model $model -BaseRef $baseRef -Review $review -DiffNote $diffNote -SensitiveContentMasked $sensitiveContentMasked -MaskedContentTypes $maskedLabels
    Write-ReviewMarkdown -Path $summaryPath -Status 'failed' -Model $model -BaseRef $baseRef -Review $review -DiffNote $diffNote -SensitiveContentMasked $sensitiveContentMasked -MaskedContentTypes $maskedLabels
    Get-Content -LiteralPath $summaryPath -Raw | Add-Content -Path $env:GITHUB_STEP_SUMMARY

    Set-WorkflowOutput -Name 'review_status' -Value 'failed'
    Set-WorkflowOutput -Name 'comment_path' -Value $commentPath
    Set-WorkflowOutput -Name 'summary_path' -Value $summaryPath
    Set-WorkflowOutput -Name 'blocker_count' -Value '0'
    Set-WorkflowOutput -Name 'major_count' -Value '0'
    Set-WorkflowOutput -Name 'minor_count' -Value '0'
    Set-WorkflowOutput -Name 'suggestion_count' -Value '0'
    Set-WorkflowOutput -Name 'should_notify_slack' -Value 'true'
    Set-WorkflowOutput -Name 'sensitive_content_masked' -Value ($sensitiveContentMasked.ToString().ToLowerInvariant())
    Set-WorkflowOutput -Name 'masked_content_types' -Value ($maskedLabels -join ',')
    Set-WorkflowOutput -Name 'model_used' -Value $model
}
