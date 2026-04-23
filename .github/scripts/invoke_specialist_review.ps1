. "$PSScriptRoot\ai_orchestration_common.ps1"

$tempRoot = Get-TempRoot
$reviewer = [string]$env:SPECIALIST_REVIEWER
if ([string]::IsNullOrWhiteSpace($reviewer)) {
    throw 'SPECIALIST_REVIEWER environment variable is required.'
}

$reviewContextPath = [string]$env:REVIEW_CONTEXT_PATH
if ([string]::IsNullOrWhiteSpace($reviewContextPath) -or -not (Test-Path -LiteralPath $reviewContextPath)) {
    throw 'REVIEW_CONTEXT_PATH environment variable is required and must point to an existing file.'
}

$resultPath = Join-Path $tempRoot "ai-orchestrator-$reviewer-result.json"
$model = if ([string]::IsNullOrWhiteSpace($env:OPENAI_MODEL)) { 'gpt-5.4-mini' } else { [string]$env:OPENAI_MODEL }
$requestTimeoutSeconds = 90

function New-SpecialistResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reviewer,
        [Parameter(Mandatory = $true)]
        [string]$Summary,
        [Parameter(Mandatory = $true)]
        [string]$RiskLevel,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Findings,
        [Parameter(Mandatory = $true)]
        [bool]$ShouldEscalate,
        [Parameter(Mandatory = $true)]
        [string]$EscalationReason,
        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    return [pscustomobject]@{
        reviewer          = $Reviewer
        summary           = $Summary
        risk_level        = $RiskLevel
        findings          = $Findings
        should_escalate   = $ShouldEscalate
        escalation_reason = $EscalationReason
        review_status     = $Status
    }
}

function Get-SpecialistInstructions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reviewer
    )

    switch ($Reviewer) {
        'dx12_lifetime_sync' {
            return @"
You are the DX12 lifetime and synchronization specialist for the dx12_Graphics repository.
Prioritize resource lifetime, ownership, destruction order, fence usage, command queue ordering, descriptor safety, and state transitions.
Ignore style concerns unless they directly hide a correctness issue.
If the current diff is docs-only, return no findings and explain that no DX12 runtime review was needed.
Write all user-facing prose in Korean.
Keep enum values exactly as specified in the schema.
Return at most 4 findings.
"@
        }
        'regression_testing' {
            return @"
You are the regression and verification specialist for the dx12_Graphics repository.
Prioritize initialization omissions, API misuse, behavior regressions, missing test or verification steps, and gaps against the repository testing strategy.
Do not spend tokens on naming or formatting comments.
If the current diff is docs-only, return no findings and explain that runtime regression review was not needed.
Write all user-facing prose in Korean.
Keep enum values exactly as specified in the schema.
Return at most 4 findings.
"@
        }
        default {
            throw "Unsupported specialist reviewer type: $Reviewer"
        }
    }
}

try {
    $context = Read-JsonUtf8 -Path $reviewContextPath

    if (@($context.scope_tags) -contains 'context_collection_failed') {
        $collectionError = ''
        if ($null -ne $context.PSObject.Properties['collection_error']) {
            $collectionError = [string]$context.collection_error
        }

        $summary = '리뷰 컨텍스트 수집에 실패하여 전문 리뷰를 신뢰할 수 없습니다.'
        if (-not [string]::IsNullOrWhiteSpace($collectionError)) {
            $summary = "$summary 원인: $collectionError"
        }

        $result = New-SpecialistResult `
            -Reviewer $reviewer `
            -Summary $summary `
            -RiskLevel 'unknown' `
            -Findings @() `
            -ShouldEscalate $true `
            -EscalationReason 'context_collection_failed' `
            -Status 'failed'

        Write-JsonUtf8 -Path $resultPath -Value $result
        Set-WorkflowOutput -Name 'result_path' -Value $resultPath
        Set-WorkflowOutput -Name 'review_status' -Value 'failed'
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
        $result = New-SpecialistResult `
            -Reviewer $reviewer `
            -Summary 'OPENAI_API_KEY가 없어 전문 리뷰를 건너뛰었습니다.' `
            -RiskLevel 'unknown' `
            -Findings @() `
            -ShouldEscalate $false `
            -EscalationReason 'missing_openai_api_key' `
            -Status 'skipped'

        Write-JsonUtf8 -Path $resultPath -Value $result
        Set-WorkflowOutput -Name 'result_path' -Value $resultPath
        Set-WorkflowOutput -Name 'review_status' -Value 'skipped'
        exit 0
    }

    if ($context.is_docs_only) {
        $result = New-SpecialistResult `
            -Reviewer $reviewer `
            -Summary '문서 전용 변경으로 판단되어 전문 코드 리뷰를 생략했습니다.' `
            -RiskLevel 'low' `
            -Findings @() `
            -ShouldEscalate $false `
            -EscalationReason 'docs_only' `
            -Status 'skipped'

        Write-JsonUtf8 -Path $resultPath -Value $result
        Set-WorkflowOutput -Name 'result_path' -Value $resultPath
        Set-WorkflowOutput -Name 'review_status' -Value 'skipped'
        exit 0
    }

    $instructions = Get-SpecialistInstructions -Reviewer $reviewer
    $changedFiles = @($context.changed_files)
    $changedFilesBlock = if ($changedFiles.Count -gt 0) { $changedFiles -join "`n" } else { '(none)' }
    $prBody = Get-BoundedText -Text ([string]$context.pr_body) -MaxLength 5000 -Label 'pull request body'

    $userPrompt = @"
Repository review rules (excerpt):
$($context.review_rules_excerpt)

Repository testing strategy (excerpt):
$($context.testing_strategy_excerpt)

Pull request template (excerpt):
$($context.pr_template_excerpt)

Pull request metadata:
- Title: $($context.pr_title)
- URL: $($context.pr_url)
- Base branch: $($context.base_ref)
- Head branch: $($context.head_ref)
- Scope tags: $(@($context.scope_tags) -join ', ')

Pull request body:
$prBody

Changed files:
$changedFilesBlock

$($context.changed_files_note)

Unified diff:
$($context.diff_text)
"@

    $schema = @{
        type                 = 'object'
        additionalProperties = $false
        properties           = @{
            reviewer          = @{ type = 'string'; enum = @('dx12_lifetime_sync', 'regression_testing') }
            summary           = @{ type = 'string' }
            risk_level        = @{ type = 'string'; enum = @('low', 'medium', 'high', 'unknown') }
            findings          = @{
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
            should_escalate   = @{ type = 'boolean' }
            escalation_reason = @{ type = 'string' }
        }
        required             = @('reviewer', 'summary', 'risk_level', 'findings', 'should_escalate', 'escalation_reason')
    }

    $body = @{
        model        = $model
        instructions = $instructions
        input        = $userPrompt
        reasoning    = @{
            effort = 'low'
        }
        text         = @{
            format = @{
                type   = 'json_schema'
                name   = 'specialist_review'
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

    $result = $rawText | ConvertFrom-Json
    $result | Add-Member -NotePropertyName review_status -NotePropertyValue 'completed' -Force

    Write-JsonUtf8 -Path $resultPath -Value $result
    Set-WorkflowOutput -Name 'result_path' -Value $resultPath
    Set-WorkflowOutput -Name 'review_status' -Value 'completed'
}
catch {
    $result = New-SpecialistResult `
        -Reviewer $reviewer `
        -Summary "전문 리뷰 실행에 실패했습니다: $($_.Exception.Message)" `
        -RiskLevel 'unknown' `
        -Findings @() `
        -ShouldEscalate $true `
        -EscalationReason 'specialist_review_failed' `
        -Status 'failed'

    Write-JsonUtf8 -Path $resultPath -Value $result
    Set-WorkflowOutput -Name 'result_path' -Value $resultPath
    Set-WorkflowOutput -Name 'review_status' -Value 'failed'
}
