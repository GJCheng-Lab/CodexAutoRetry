# Read-only diagnostics entry point.
param([long]$Handle=0)
if(-not $Handle){
  Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
  $windows=[System.Windows.Automation.AutomationElement]::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.Condition]::TrueCondition)
  $candidate=$windows | ForEach-Object {
    $c=$_.Current;$r=$c.BoundingRectangle
    if($c.Name -eq 'ChatGPT' -and $r.Width -gt 500 -and $r.Height -gt 500){
      [pscustomobject]@{Handle=$c.NativeWindowHandle;Area=$r.Width*$r.Height}
    }
  } | Sort-Object Area -Descending | Select-Object -First 1
  if($candidate){$Handle=$candidate.Handle}
}
if(-not $Handle){Write-Output 'WINDOW_NOT_FOUND';exit 2}
& (Join-Path $PSScriptRoot 'UiaRetry.ps1') -Handle $Handle -Mode probe
Write-Output '--- LOG CAPACITY EVENTS ---'
& (Join-Path $PSScriptRoot 'CodexLogReader.ps1')
