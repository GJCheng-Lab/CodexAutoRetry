<#
  Read-only Codex state reader.
  It reads only thread metadata and the latest turn status/error fields.
  It does not read rollout bodies, prompts, tool output, credentials, or
  write any Codex database.
#>
param(
  [string]$StateDb = (Join-Path $env:USERPROFILE '.codex\state_5.sqlite'),
  [string]$HistoryDb = (Join-Path $env:USERPROFILE '.codex\thread_history_1.sqlite'),
  [string]$OutFile = '',
  [int]$MaxAgeHours = 24
)

$ErrorActionPreference='Stop'
$records=New-Object 'System.Collections.Generic.List[string]'
function Clean([object]$v) {
  if($null -eq $v){ return '' }
  return (([string]$v) -replace '[\t\r\n]+',' ' -replace '\|','/')
}
function TitlePreview([object]$v) {
  $s=Clean $v
  if($s.Length -gt 120){ return $s.Substring(0,120) }
  return $s
}
function Emit([string]$s) { [void]$records.Add($s) }
function Finish() {
  if($OutFile) {
    [IO.File]::WriteAllLines($OutFile,$records,(New-Object Text.UTF8Encoding($false)))
  } else {
    $records
  }
}

if(-not (Test-Path -LiteralPath $StateDb) -or -not (Test-Path -LiteralPath $HistoryDb)) {
  Emit 'STATE_READER_UNAVAILABLE|Missing Codex state database.'
  Finish
  exit 0
}
$sqlite=(Get-Command sqlite3.exe -ErrorAction SilentlyContinue).Source
if(-not $sqlite) {
  Emit 'STATE_READER_UNAVAILABLE|sqlite3.exe was not found on PATH.'
  Finish
  exit 0
}

$stateSql=$StateDb.Replace("'","''")
$cutoff=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()-([Math]::Max(1,$MaxAgeHours)*3600)
$sql=@"
ATTACH '$stateSql' AS state;
WITH latest AS (
  SELECT thread_id, MAX(rollout_ordinal) AS rollout_ordinal
  FROM main.thread_turns
  GROUP BY thread_id
)
SELECT
  tt.thread_id,
  tt.turn_id,
  tt.status,
  COALESCE(json_extract(tt.error_json,'$.codexErrorInfo'),''),
  COALESCE(json_extract(tt.error_json,'$.message'),''),
  COALESCE(t.project_id,''),
  COALESCE(p.name,''),
  replace(replace(replace(COALESCE(NULLIF(t.name,''),''),char(10),' '),char(13),' '),'|','/'),
  replace(replace(replace(COALESCE(t.cwd,''),char(10),' '),char(13),' '),'|','/'),
  COALESCE(tt.completed_at,tt.started_at)
FROM main.thread_turns tt
JOIN latest l ON l.thread_id=tt.thread_id AND l.rollout_ordinal=tt.rollout_ordinal
LEFT JOIN state.threads t ON t.id=tt.thread_id
LEFT JOIN state.projects p ON p.id=t.project_id
WHERE tt.status='failed'
  AND COALESCE(tt.completed_at,tt.started_at) >= $cutoff
  AND (
    lower(COALESCE(json_extract(tt.error_json,'$.message'),'')) LIKE 'selected model is at capacity%'
    OR json_extract(tt.error_json,'$.codexErrorInfo')='serverOverloaded'
  )
ORDER BY COALESCE(tt.completed_at,tt.started_at) DESC;
"@

try {
  $rows=@(& $sqlite -readonly -separator '|' $HistoryDb $sql 2>$null)
  foreach($row in $rows) {
    if([string]::IsNullOrWhiteSpace($row)){ continue }
    $p=$row -split '\|',10
    if($p.Count -lt 10){ continue }
    Emit ("STATE_FAILURE|thread_id={0}|turn_id={1}|status={2}|error_code={3}|message={4}|project_id={5}|project={6}|title={7}|cwd={8}|time={9}" -f
      (Clean $p[0]),(Clean $p[1]),(Clean $p[2]),(Clean $p[3]),(Clean $p[4]),(Clean $p[5]),(Clean $p[6]),(TitlePreview $p[7]),(Clean $p[8]),(Clean $p[9]))
  }
  Emit ("STATE_SCOPE|latest_failed_capacity_turns={0}|max_age_hours={1}|scope=local_Codex_state_only|source=thread_history_1.sqlite+state_5.sqlite|mode=read_only" -f $rows.Count,$MaxAgeHours)
} catch {
  Emit ("STATE_READER_ERROR|{0}" -f (Clean $_.Exception.Message))
}
Finish
