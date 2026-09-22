# Settings for PSScriptAnalyzer, so `Invoke-ScriptAnalyzer -Path . -Recurse
# -Settings .\PSScriptAnalyzerSettings.psd1` gives the same answer here as in
# CI. Only rules this repository breaks on purpose are excluded; each is
# excluded for a reason, not to make the list shorter.
@{
    ExcludeRules = @(
        # Logging and the window must never throw on the way out of a failure.
        # Every one of these blocks is commented where it sits.
        'PSAvoidUsingEmptyCatchBlock'

        # The CLI wrapper is talking to a console on purpose.
        'PSAvoidUsingWriteHost'

        # Write-Log is private to the module and never exported, so nothing
        # outside it is shadowed.
        'PSAvoidOverwritingBuiltInCmdlets'
    )
}
