BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    Import-AirlockForTest

    # A run whose cmdlet answers ShouldProcess the way the test says: $true to go ahead,
    # $false for -WhatIf or a declined -Confirm prompt.
    function New-StepRun {
        param([bool]$Answer = $true, [bool]$IsWhatIf = $false)
        $cmdlet = [pscustomobject]@{ Answer = $Answer }
        $cmdlet | Add-Member -MemberType ScriptMethod -Name ShouldProcess -Value { param($Target, $Action) $this.Answer }
        InModuleScope Airlock -Parameters @{ Cmdlet = $cmdlet; IsWhatIf = $IsWhatIf } -ScriptBlock {
            param($Cmdlet, $IsWhatIf)
            New-AirlockRun -Command 'New-AirlockUser' -Cmdlet $Cmdlet -IsWhatIf $IsWhatIf -LogDirectory 'unused'
        }
    }

    # Builds a finished set of entries for one user and asks each completer for the outcome.
    function Get-Outcome {
        param([string]$Kind, [string[]]$Statuses, [bool]$IsWhatIf = $false, [bool]$Created = $false)
        InModuleScope Airlock -Parameters @{ Kind = $Kind; Statuses = $Statuses; IsWhatIf = $IsWhatIf; Created = $Created } -ScriptBlock {
            param($Kind, $Statuses, $IsWhatIf, $Created)
            $run = New-AirlockRun -Command 'New-AirlockUser' -Cmdlet ([pscustomobject]@{}) -IsWhatIf $IsWhatIf -LogDirectory 'unused'
            foreach ($status in $Statuses) {
                Add-AirlockLogEntry -Run $run -Target 'ada.example@contoso.example' -Action 'AddGroup' -Status $status -Detail "detail for $status"
            }
            $result = [pscustomobject]@{ Outcome = 'Failed'; Created = $Created; Error = $null; Actions = @() }
            if ($Kind -eq 'On') {
                (Complete-AirlockOnboarding -Run $run -Result $result -StartIndex 0).Outcome
            }
            else {
                (Complete-AirlockOffboarding -Run $run -Result $result -StartIndex 0).Outcome
            }
        }
    }

    function Invoke-TestStep {
        param($Run, [scriptblock]$Do, [switch]$Retry)
        InModuleScope Airlock -Parameters @{ Run = $Run; Do = $Do; Retry = $Retry } -ScriptBlock {
            param($Run, $Do, $Retry)
            Invoke-AirlockStep -Run $Run -Target 'ada.example@contoso.example' -Action 'AddGroup' -Detail 'Engineering' -Do $Do -RetryOnReplication:$Retry
        }
    }
}

AfterAll {
    Remove-Variable -Name StepCalls -Scope Global -ErrorAction SilentlyContinue
    Remove-AirlockTestStubs
}

Describe 'Invoke-AirlockStep' {
    BeforeEach {
        $global:StepCalls = 0
        Mock -ModuleName Airlock Start-Sleep -MockWith { }
    }

    Context 'ShouldProcess' {
        It 'runs the step and records Applied' {
            $run = New-StepRun
            $step = Invoke-TestStep -Run $run -Do { $global:StepCalls++; 'result' }

            $step.Status | Should -Be 'Applied'
            $step.Result | Should -Be 'result'
            $global:StepCalls | Should -Be 1
            $run.Entries[0].Status | Should -Be 'Applied'
            $run.Entries[0].Detail | Should -Be 'Engineering'
        }

        It 'does not run the step under -WhatIf and records WhatIf' {
            $run = New-StepRun -Answer $false -IsWhatIf $true
            $step = Invoke-TestStep -Run $run -Do { $global:StepCalls++ }

            $step.Status | Should -Be 'WhatIf'
            $global:StepCalls | Should -Be 0
            $run.Entries[0].Status | Should -Be 'WhatIf'
        }

        It 'does not run the step when the prompt is declined, and records Declined, not Skipped' {
            $run = New-StepRun -Answer $false -IsWhatIf $false
            $step = Invoke-TestStep -Run $run -Do { $global:StepCalls++ }

            $step.Status | Should -Be 'Declined'
            $global:StepCalls | Should -Be 0
            $run.Entries[0].Status | Should -Be 'Declined'
            $run.Entries[0].Detail | Should -Match 'Declined at the confirmation prompt'
            $run.Entries[0].Detail | Should -Match 'Engineering'
        }
    }

    Context 'failure' {
        It 'records Failed with the message and does not throw' {
            $run = New-StepRun
            $step = Invoke-TestStep -Run $run -Do { $global:StepCalls++; throw 'Request_BadRequest: simulated' }

            $step.Status | Should -Be 'Failed'
            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[0].Detail | Should -Be 'Request_BadRequest: simulated'
            $global:StepCalls | Should -Be 1
            Should -Invoke -CommandName Start-Sleep -ModuleName Airlock -Times 0 -Exactly
        }
    }

    Context 'replication retry' {
        It 'retries an error that says the object does not exist, with growing pauses, then succeeds' {
            $run = New-StepRun
            $step = Invoke-TestStep -Retry -Run $run -Do {
                $global:StepCalls++
                if ($global:StepCalls -le 2) { throw 'Request_ResourceNotFound: Resource does not exist or one of its queried reference-property objects are not present.' }
                'ok'
            }

            $step.Status | Should -Be 'Applied'
            $global:StepCalls | Should -Be 3
            Should -Invoke -CommandName Start-Sleep -ModuleName Airlock -Times 2 -Exactly
            Should -Invoke -CommandName Start-Sleep -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
            Should -Invoke -CommandName Start-Sleep -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $Seconds -eq 4 }
            $run.Entries.Count | Should -Be 1
            $run.Entries[0].Status | Should -Be 'Applied'
            $run.Entries[0].Detail | Should -Match 'succeeded after 2 retries'
        }

        It 'gives up after four retries and tells the operator to run the command again' {
            $run = New-StepRun
            $step = Invoke-TestStep -Retry -Run $run -Do {
                $global:StepCalls++
                throw 'Request_ResourceNotFound: Resource does not exist'
            }

            $step.Status | Should -Be 'Failed'
            $global:StepCalls | Should -Be 5
            Should -Invoke -CommandName Start-Sleep -ModuleName Airlock -Times 4 -Exactly
            Should -Invoke -CommandName Start-Sleep -ModuleName Airlock -Times 1 -Exactly -ParameterFilter { $Seconds -eq 16 }
            $run.Entries[0].Status | Should -Be 'Failed'
            $run.Entries[0].Detail | Should -Match 'Resource does not exist'
            $run.Entries[0].Detail | Should -Match 'replication'
            $run.Entries[0].Detail | Should -Match 'Run the command again'
        }

        It 'does not retry without the switch, even for an error that looks like replication' {
            $run = New-StepRun
            $step = Invoke-TestStep -Run $run -Do {
                $global:StepCalls++
                throw 'Request_ResourceNotFound: Resource does not exist'
            }

            $step.Status | Should -Be 'Failed'
            $global:StepCalls | Should -Be 1
            Should -Invoke -CommandName Start-Sleep -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Detail | Should -Not -Match 'replication'
        }

        It 'does not retry an error that is not about a missing object' {
            $run = New-StepRun
            $step = Invoke-TestStep -Retry -Run $run -Do {
                $global:StepCalls++
                throw 'Authorization_RequestDenied: Insufficient privileges'
            }

            $step.Status | Should -Be 'Failed'
            $global:StepCalls | Should -Be 1
            Should -Invoke -CommandName Start-Sleep -ModuleName Airlock -Times 0 -Exactly
            $run.Entries[0].Detail | Should -Not -Match 'replication'
        }

        It 'does not pause or retry under -WhatIf' {
            $run = New-StepRun -Answer $false -IsWhatIf $true
            Invoke-TestStep -Retry -Run $run -Do { $global:StepCalls++; throw 'does not exist' } | Out-Null

            $global:StepCalls | Should -Be 0
            Should -Invoke -CommandName Start-Sleep -ModuleName Airlock -Times 0 -Exactly
        }
    }
}

Describe 'Complete-AirlockOnboarding and Complete-AirlockOffboarding' {
    It 'onboarding: <Statuses> gives <Expected>' -ForEach @(
        @{ Statuses = @('Applied', 'Skipped'); Created = $true; IsWhatIf = $false; Expected = 'Created' }
        @{ Statuses = @('Skipped', 'Skipped'); Created = $false; IsWhatIf = $false; Expected = 'Existing' }
        @{ Statuses = @('Declined', 'Declined'); Created = $false; IsWhatIf = $false; Expected = 'Declined' }
        @{ Statuses = @('Skipped', 'Declined'); Created = $false; IsWhatIf = $false; Expected = 'Declined' }
        @{ Statuses = @('Applied', 'Declined'); Created = $true; IsWhatIf = $false; Expected = 'Declined' }
        @{ Statuses = @('Applied', 'Declined', 'Failed'); Created = $true; IsWhatIf = $false; Expected = 'Failed' }
        @{ Statuses = @('WhatIf', 'WhatIf'); Created = $false; IsWhatIf = $true; Expected = 'WhatIf' }
    ) {
        Get-Outcome -Kind 'On' -Statuses $Statuses -Created $Created -IsWhatIf $IsWhatIf | Should -Be $Expected
    }

    It 'offboarding: <Statuses> gives <Expected>' -ForEach @(
        @{ Statuses = @('Applied', 'Skipped'); IsWhatIf = $false; Expected = 'Offboarded' }
        @{ Statuses = @('Skipped', 'Info'); IsWhatIf = $false; Expected = 'AlreadyOffboarded' }
        @{ Statuses = @('Declined', 'Declined', 'Info'); IsWhatIf = $false; Expected = 'Declined' }
        @{ Statuses = @('Skipped', 'Declined'); IsWhatIf = $false; Expected = 'Declined' }
        @{ Statuses = @('Applied', 'Declined'); IsWhatIf = $false; Expected = 'Declined' }
        @{ Statuses = @('Applied', 'Declined', 'Failed'); IsWhatIf = $false; Expected = 'Failed' }
        @{ Statuses = @('WhatIf', 'Info'); IsWhatIf = $true; Expected = 'WhatIf' }
    ) {
        Get-Outcome -Kind 'Off' -Statuses $Statuses -IsWhatIf $IsWhatIf | Should -Be $Expected
    }
}
