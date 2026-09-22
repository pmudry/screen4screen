@{
    RootModule        = 'WallpaperByResolution.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b7c4f2a1-9d3e-4c58-8f06-2a1e5d7b4c93'
    Author            = 'Pierre-Andre Mudry'
    Description       = 'Per-monitor Windows wallpapers, chosen from each monitor native resolution.'

    PowerShellVersion = '5.1'

    FunctionsToExport = @(
        'Get-AttachedDisplay'
        'Get-DisplaySignature'
        'Get-WallpaperAssignment'
        'Get-WallpaperLogPath'
        'Get-WallpaperPlan'
        'Get-WallpaperPosition'
        'Get-WallpaperTaskState'
        'Install-WallpaperTask'
        'Remove-WallpaperAssignment'
        'Resolve-WallpaperFile'
        'Set-MonitorWallpaper'
        'Set-WallpaperAssignment'
        'Set-WallpapersNow'
        'Start-WallpaperWatch'
        'Uninstall-WallpaperTask'
    )

    # Never '*': it defeats command discovery and slows import.
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('Wallpaper', 'Monitor', 'Desktop', 'Windows')
            ProjectUri = 'https://github.com/pmudry/wallpaper-by-resolution'
        }
    }
}
