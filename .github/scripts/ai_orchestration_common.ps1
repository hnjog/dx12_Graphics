Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-WorkflowOutput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [AllowNull()]
        [string]$Value = ''
    )

    if ($env:GITHUB_OUTPUT) {
        $safeValue = [string]$Value
        if ($safeValue -match "[`r`n]") {
            $delimiter = "EOF_$([guid]::NewGuid().ToString('N'))"
            Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name<<$delimiter" -Encoding utf8
            Add-Content -Path $env:GITHUB_OUTPUT -Value $safeValue -Encoding utf8
            Add-Content -Path $env:GITHUB_OUTPUT -Value $delimiter -Encoding utf8
        }
        else {
            Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$safeValue" -Encoding utf8
        }
    }
}

function Write-JsonUtf8 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $Value | ConvertTo-Json -Depth 100 | Set-Content -Path $Path -Encoding utf8
}

function Read-JsonUtf8 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json)
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
            $detail = Get-OpenAIErrorDetail -Exception $_.Exception
            $isTimeout = Test-IsTimeoutException -Exception $_.Exception

            if (($statusCode -eq 429 -or $isTimeout) -and $attempt -lt $MaxAttempts) {
                $delaySeconds = [Math]::Min(20, [int][Math]::Pow(2, $attempt))
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

    throw 'OpenAI Responses API request failed without returning a response.'
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

function Test-IsBenignReferenceValue {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    $candidate = [string]$Value
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        return $true
    }

    $trimmed = $candidate.Trim()
    if ($trimmed -match '^(?i:true|false|null|none)$') {
        return $true
    }

    if ($trimmed -match '^\d+$') {
        return $true
    }

    if ($trimmed -match '^(?:\$|%|\$\{\{)') {
        return $true
    }

    if ($trimmed -match '^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)+$') {
        return $true
    }

    if ($trimmed -match '^[A-Za-z_][A-Za-z0-9_]*\([^)]*\)$') {
        return $true
    }

    return $false
}

function Protect-InlineCredentialAssignments {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    $value = [string]$Text
    if ([string]::IsNullOrEmpty($value)) {
        return [pscustomobject]@{
            text        = $value
            match_count = 0
            labels      = @()
        }
    }

    $pattern = '(?im)\b(password|passwd|pwd|token|secret|api[_-]?key|access[_-]?key|secret_access_key|aws_secret_access_key)\b(\s*[:=]\s*)([^\r\n#;]+)'
    $regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline)

    $maskedValue = $regex.Replace($value, {
        param($match)

        $name = [string]$match.Groups[1].Value
        $separator = [string]$match.Groups[2].Value
        $rawValue = [string]$match.Groups[3].Value
        $trimmedValue = $rawValue.Trim()
        $unwrappedValue = $trimmedValue
        $quotePrefix = ''
        $quoteSuffix = ''

        if ($trimmedValue.Length -ge 2) {
            if (($trimmedValue[0] -eq '"' -and $trimmedValue[$trimmedValue.Length - 1] -eq '"') -or ($trimmedValue[0] -eq "'" -and $trimmedValue[$trimmedValue.Length - 1] -eq "'")) {
                $quotePrefix = [string]$trimmedValue[0]
                $quoteSuffix = [string]$trimmedValue[$trimmedValue.Length - 1]
                $unwrappedValue = $trimmedValue.Substring(1, $trimmedValue.Length - 2)
            }
        }

        if (Test-IsBenignReferenceValue -Value $unwrappedValue) {
            return $match.Value
        }

        $replacementLabel = 'inline_credential'
        $replacementValue = '[REDACTED_CREDENTIAL]'
        $looksSensitive = $false

        if ($unwrappedValue -match '^https://hooks\.slack(?:-gov)?\.com/services/[A-Za-z0-9/_-]+$') {
            $replacementLabel = 'slack_webhook'
            $replacementValue = '[REDACTED_SLACK_WEBHOOK]'
            $looksSensitive = $true
        }
        elseif ($unwrappedValue -match '^sk-[A-Za-z0-9][A-Za-z0-9_-]{12,}$') {
            $replacementLabel = 'openai_key'
            $replacementValue = '[REDACTED_OPENAI_KEY]'
            $looksSensitive = $true
        }
        elseif ($unwrappedValue -match '^(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}$|^github_pat_[A-Za-z0-9_]{20,}$') {
            $replacementLabel = 'github_token'
            $replacementValue = '[REDACTED_GITHUB_TOKEN]'
            $looksSensitive = $true
        }
        elseif ($unwrappedValue -match '^xox[baprs]-[A-Za-z0-9-]{10,}$') {
            $replacementLabel = 'slack_token'
            $replacementValue = '[REDACTED_SLACK_TOKEN]'
            $looksSensitive = $true
        }
        elseif ($unwrappedValue -match '^AKIA[0-9A-Z]{16}$') {
            $replacementLabel = 'aws_access_key'
            $replacementValue = '[REDACTED_AWS_ACCESS_KEY]'
            $looksSensitive = $true
        }
        elseif ($unwrappedValue -match '^[A-Za-z0-9/+=]{40}$' -and $name -match '^(?i:aws_secret_access_key|secret_access_key|access_key|api_key|token|secret)$') {
            $replacementLabel = 'aws_secret_access_key'
            $replacementValue = '[REDACTED_AWS_SECRET_KEY]'
            $looksSensitive = $true
        }
        elseif ($unwrappedValue -match '^Bearer\s+[A-Za-z0-9._~+/\-=]{10,}$') {
            $replacementLabel = 'bearer_token'
            $replacementValue = 'Bearer [REDACTED_BEARER_TOKEN]'
            $looksSensitive = $true
        }
        elseif ($name -match '^(?i:password|passwd|pwd|secret|secret_access_key|aws_secret_access_key)$') {
            $looksSensitive = $true
        }
        elseif ($name -match '^(?i:token|api[_-]?key|access[_-]?key)$' -and $unwrappedValue.Length -ge 6) {
            $looksSensitive = $true
        }
        elseif ($unwrappedValue.Length -ge 12 -and $unwrappedValue -match '^[A-Za-z0-9_/\-+=]+$' -and $unwrappedValue -match '[0-9/\-+=]') {
            $looksSensitive = $true
        }

        if (-not $looksSensitive) {
            return $match.Value
        }

        if ($replacementValue -like 'Bearer *') {
            return "$name$separator$replacementValue"
        }

        if ($quotePrefix) {
            return "$name$separator$quotePrefix$replacementValue$quoteSuffix"
        }

        return "$name$separator$replacementValue"
    })

    $placeholderMap = @{
        '[REDACTED_SLACK_WEBHOOK]' = 'slack_webhook'
        '[REDACTED_OPENAI_KEY]' = 'openai_key'
        '[REDACTED_GITHUB_TOKEN]' = 'github_token'
        '[REDACTED_SLACK_TOKEN]' = 'slack_token'
        '[REDACTED_AWS_ACCESS_KEY]' = 'aws_access_key'
        '[REDACTED_AWS_SECRET_KEY]' = 'aws_secret_access_key'
        'Bearer [REDACTED_BEARER_TOKEN]' = 'bearer_token'
        '[REDACTED_CREDENTIAL]' = 'inline_credential'
    }

    $labels = New-Object System.Collections.Generic.List[string]
    $matchCount = 0
    foreach ($placeholder in $placeholderMap.Keys) {
        $placeholderCount = ([regex]::Matches($maskedValue, [regex]::Escape($placeholder))).Count
        if ($placeholderCount -gt 0) {
            $matchCount += $placeholderCount
            $labels.Add([string]$placeholderMap[$placeholder]) | Out-Null
        }
    }

    return [pscustomobject]@{
        text        = $maskedValue
        match_count = $matchCount
        labels      = @($labels | Select-Object -Unique)
    }
}

function Protect-SensitiveText {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    $value = [string]$Text
    if ([string]::IsNullOrEmpty($value)) {
        return [pscustomobject]@{
            text                  = $value
            has_sensitive_content = $false
            match_count           = 0
            labels                = @()
        }
    }

    $labels = New-Object System.Collections.Generic.List[string]
    $matchCount = 0
    $rules = @(
        @{ Pattern = 'https://hooks\.slack(?:-gov)?\.com/services/[A-Za-z0-9/_-]+'; Replacement = '[REDACTED_SLACK_WEBHOOK]'; Label = 'slack_webhook'; Options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase },
        @{ Pattern = '\bsk-[A-Za-z0-9][A-Za-z0-9_-]{12,}\b'; Replacement = '[REDACTED_OPENAI_KEY]'; Label = 'openai_key'; Options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase },
        @{ Pattern = '\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}\b|\bgithub_pat_[A-Za-z0-9_]{20,}\b'; Replacement = '[REDACTED_GITHUB_TOKEN]'; Label = 'github_token'; Options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase },
        @{ Pattern = '\bxox[baprs]-[A-Za-z0-9-]{10,}\b'; Replacement = '[REDACTED_SLACK_TOKEN]'; Label = 'slack_token'; Options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase },
        @{ Pattern = '\bAKIA[0-9A-Z]{16}\b'; Replacement = '[REDACTED_AWS_ACCESS_KEY]'; Label = 'aws_access_key'; Options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase },
        @{ Pattern = '\bBearer\s+[A-Za-z0-9._~+/\-=]{10,}\b'; Replacement = 'Bearer [REDACTED_BEARER_TOKEN]'; Label = 'bearer_token'; Options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase },
        @{ Pattern = '(?s)-----BEGIN(?: [A-Z]+)* PRIVATE KEY-----.+?-----END(?: [A-Z]+)* PRIVATE KEY-----'; Replacement = '[REDACTED_PRIVATE_KEY]'; Label = 'private_key'; Options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase }
    )

    foreach ($rule in $rules) {
        $regex = [regex]::new([string]$rule.Pattern, [System.Text.RegularExpressions.RegexOptions]$rule.Options)
        $matches = $regex.Matches($value)
        if ($matches.Count -gt 0) {
            $matchCount += $matches.Count
            $labels.Add([string]$rule.Label) | Out-Null
            $value = $regex.Replace($value, [string]$rule.Replacement)
        }
    }

    $inlineCredentialResult = Protect-InlineCredentialAssignments -Text $value
    $value = [string]$inlineCredentialResult.text
    if ($inlineCredentialResult.match_count -gt 0) {
        $matchCount += [int]$inlineCredentialResult.match_count
        foreach ($label in @($inlineCredentialResult.labels)) {
            $labels.Add([string]$label) | Out-Null
        }
    }

    return [pscustomobject]@{
        text                  = $value
        has_sensitive_content = ($labels.Count -gt 0)
        match_count           = $matchCount
        labels                = @($labels | Select-Object -Unique)
    }
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
            $normalizedPath -match '^dx12engine/'
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

function Get-TempRoot {
    if ($env:RUNNER_TEMP) {
        return $env:RUNNER_TEMP
    }

    return (Get-Location).Path
}

function Get-OrchestrationScopeTags {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ChangedFiles
    )

    $tags = New-Object System.Collections.Generic.HashSet[string]

    if ($ChangedFiles.Count -eq 0) {
        $tags.Add('no_diff') | Out-Null
        return @($tags)
    }

    $docsOnly = $true
    foreach ($path in $ChangedFiles) {
        $normalizedPath = ([string]$path).Replace('\', '/').ToLowerInvariant()
        $extension = [System.IO.Path]::GetExtension($normalizedPath).ToLowerInvariant()

        if ($normalizedPath -match '^docs/' -or $extension -eq '.md') {
            $tags.Add('docs') | Out-Null
        }
        else {
            $docsOnly = $false
        }

        if ($normalizedPath -match '^\.github/' -or $extension -in @('.ps1', '.yml', '.yaml')) {
            $tags.Add('automation') | Out-Null
        }

        if ($normalizedPath -match 'dx12|renderer|swapchain|command|fence|resource|descriptor|platform/win32') {
            $tags.Add('dx12_high_risk') | Out-Null
        }

        if ($normalizedPath -match '\.(cpp|c|cc|h|hpp|hxx|inl|hlsl|hlsli)$') {
            $tags.Add('code') | Out-Null
        }
    }

    if ($docsOnly) {
        $tags.Add('docs_only') | Out-Null
    }

    return @($tags | Sort-Object)
}

function Get-OrchestrationExecutionPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ScopeTags,
        [Parameter(Mandatory = $true)]
        [int]$ChangedFileCount,
        [bool]$DiffWasTruncated = $false
    )

    $tags = @($ScopeTags)
    $isContextFailed = $tags -contains 'context_collection_failed'
    $isDocsOnly = $tags -contains 'docs_only'
    $hasNoDiff = $tags -contains 'no_diff'
    $hasCode = $tags -contains 'code'
    $hasAutomation = $tags -contains 'automation'
    $hasDx12Risk = $tags -contains 'dx12_high_risk'
    $shouldReview = -not $isContextFailed -and -not $isDocsOnly -and -not $hasNoDiff -and $ChangedFileCount -gt 0

    $runDx12Specialist = $shouldReview -and ($hasDx12Risk -or $hasCode)
    $runRegressionSpecialist = $shouldReview
    $allowOpenAiModerator = $shouldReview -and ($runDx12Specialist -or $runRegressionSpecialist -or $DiffWasTruncated)

    $reasons = New-Object System.Collections.Generic.List[string]
    if ($isContextFailed) {
        $reasons.Add('context_collection_failed') | Out-Null
    }
    elseif ($isDocsOnly) {
        $reasons.Add('docs_only') | Out-Null
    }
    elseif ($hasNoDiff -or $ChangedFileCount -eq 0) {
        $reasons.Add('no_diff') | Out-Null
    }
    else {
        if ($hasDx12Risk) {
            $reasons.Add('dx12_high_risk') | Out-Null
        }
        if ($hasCode) {
            $reasons.Add('code_change') | Out-Null
        }
        if ($hasAutomation) {
            $reasons.Add('automation_change') | Out-Null
        }
        if ($DiffWasTruncated) {
            $reasons.Add('partial_diff') | Out-Null
        }
    }

    if ($reasons.Count -eq 0) {
        $reasons.Add('low_risk_change') | Out-Null
    }

    return [pscustomobject]@{
        mode                         = 'conditional'
        run_dx12_specialist          = [bool]$runDx12Specialist
        run_regression_specialist    = [bool]$runRegressionSpecialist
        allow_openai_moderator       = [bool]$allowOpenAiModerator
        moderator_policy             = 'for_partial_diff_or_findings_or_untrusted_verification'
        reason                       = ($reasons -join ',')
    }
}
