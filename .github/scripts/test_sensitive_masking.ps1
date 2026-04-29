Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot/ai_orchestration_common.ps1"

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Collection,
        [Parameter(Mandatory = $true)]
        [string]$Expected,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Collection -notcontains $Expected) {
        throw $Message
    }
}

$cases = @(
    @{
        name = 'slack_webhook'
        text = 'url = https://hooks.slack.com/services/T000/B000/secret-token'
        expectedLabel = 'slack_webhook'
        expectedText = '[REDACTED_SLACK_WEBHOOK]'
        expectedSensitive = $true
    },
    @{
        name = 'bearer_token'
        text = 'Authorization: Bearer sample-secret-token-value'
        expectedLabel = 'bearer_token'
        expectedText = 'Bearer [REDACTED_BEARER_TOKEN]'
        expectedSensitive = $true
    },
    @{
        name = 'private_key'
        text = "-----BEGIN PRIVATE KEY-----`nabc123`n-----END PRIVATE KEY-----"
        expectedLabel = 'private_key'
        expectedText = '[REDACTED_PRIVATE_KEY]'
        expectedSensitive = $true
    },
    @{
        name = 'inline_credential'
        text = 'password = super-secret-value'
        expectedLabel = 'inline_credential'
        expectedText = '[REDACTED_CREDENTIAL]'
        expectedSensitive = $true
    },
    @{
        name = 'aws_secret_access_key'
        text = 'aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY'
        expectedLabel = 'aws_secret_access_key'
        expectedText = '[REDACTED_AWS_SECRET_KEY]'
        expectedSensitive = $true
    },
    @{
        name = 'benign_reference'
        text = 'token = request.Token'
        expectedLabel = ''
        expectedText = 'request.Token'
        expectedSensitive = $false
    }
)

foreach ($case in $cases) {
    $result = Protect-SensitiveText -Text ([string]$case.text)

    Assert-True -Condition ($result.text -match [regex]::Escape([string]$case.expectedText)) -Message "Case '$($case.name)' did not contain expected masked text."
    Assert-True -Condition ($result.has_sensitive_content -eq [bool]$case.expectedSensitive) -Message "Case '$($case.name)' returned unexpected sensitive flag."

    if ([string]::IsNullOrWhiteSpace([string]$case.expectedLabel)) {
        Assert-True -Condition (@($result.labels).Count -eq 0) -Message "Case '$($case.name)' should not produce masking labels."
    }
    else {
        Assert-Contains -Collection @($result.labels) -Expected ([string]$case.expectedLabel) -Message "Case '$($case.name)' did not include expected label '$($case.expectedLabel)'."
    }
}

Write-Host 'Sensitive text smoke test passed.'
