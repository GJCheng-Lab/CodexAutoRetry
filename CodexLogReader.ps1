#Requires -Version 5.1
<#
  Read-only bounded log reader. It extracts only structured capacity failures
  and nearby conversation/thread/project identifiers; it never emits chat text.
#>
param(
  [string]$Root=(Join-Path $env:LOCALAPPDATA 'Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs'),
  [int]$Days=14
)
$cut=(Get-Date).AddDays(-$Days)
$files=Get-ChildItem -LiteralPath $Root -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object LastWriteTime -ge $cut
foreach($f in $files){
  $lines=Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue
  for($i=0;$i -lt $lines.Count;$i++){
    if($lines[$i] -notmatch 'Selected model is at capacity'){continue}
    $a=[Math]::Max(0,$i-12);$b=[Math]::Min($lines.Count-1,$i+12);$window=$lines[$a..$b] -join [Environment]::NewLine
    $id=[regex]::Match($window,'(?:conversationId|threadId)=([0-9a-f-]{20,})').Groups[1].Value
    $project=[regex]::Match($window,'projectRoot=([^\s]+)').Groups[1].Value
    $stamp=if($lines[$i].Length -ge 24){$lines[$i].Substring(0,24)}else{''}
    "CAPACITY|file=$($f.Name)|line=$($i+1)|time=$stamp|conversation_id=$id|project_root=$project"
  }
}
