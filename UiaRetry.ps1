#Requires -Version 5.1
<#
  Read-only UIA bridge for Codex Auto Retry.
  It never clicks, moves the mouse, activates a window, or reads chat bodies.
  Output is pipe-separated records; values are sanitized before emission.
#>
param(
  [Parameter(Mandatory=$true)][long]$Handle,
  [ValidateSet('probe','scan','sidebar-dump','locate','current','verify','invoke-session','invoke-retry','send-state','invoke-send')][string]$Mode='probe',
  [string]$Project='',
  [string]$SessionKey='',
  [string]$Title='',
  [string]$OutFile
)

$ErrorActionPreference='Stop'
$failedNames=@('Task failed',([string][char]0x4efb+[char]0x52a1+[char]0x672a+[char]0x6210+[char]0x529f),([string][char]0x4efb+[char]0x52a1+[char]0x5931+[char]0x8d25))
$retryNames=@('Retry',([string][char]0x91cd+[char]0x8bd5),([string][char]0x91cd+[char]0x8a66))
$stopNames=@('Stop',([string][char]0x505c+[char]0x6b62))
$voiceNames=@('Voice',([string][char]0x542c+[char]0x5199))

function Clean([object]$v) { if($null -eq $v){return ''}; return (([string]$v) -replace '[\t\r\n]+',' ' -replace '\|','/') }
function RectText($r) { if($null -eq $r -or $r.Width -le 0 -or $r.Height -le 0){return ''}; '{0},{1},{2},{3}' -f ([int]$r.X),([int]$r.Y),([int]$r.Width),([int]$r.Height) }
function Emit([string]$s) { $script:records.Add($s) }

$records=New-Object 'System.Collections.Generic.List[string]'
try {
  Add-Type -AssemblyName UIAutomationClient
  Add-Type -AssemblyName UIAutomationTypes
  $root=[System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]::new($Handle))
  if($null -eq $root) { Emit 'RESULT|WINDOW_GONE|Invalid HWND' }
  else {
    $all=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
    $rc=$root.Current
    Emit ("META|window_handle={0}|process_id={1}|window_name={2}|class={3}|automation_id={4}|control_type={5}|root_rect={6}" -f $rc.NativeWindowHandle,$rc.ProcessId,(Clean $rc.Name),(Clean $rc.ClassName),(Clean $rc.AutomationId),(Clean $rc.ControlType.ProgrammaticName),(RectText $rc.BoundingRectangle))

    if($Mode -eq 'probe') {
      $types=@{}; $interesting=0
      foreach($e in $all) {
        $c=$e.Current; $ct=Clean $c.ControlType.ProgrammaticName
        if(-not $types.ContainsKey($ct)){$types[$ct]=0};$types[$ct]++
        if($c.Name -match 'Task failed|Retry|capacity|429|Too Many Requests|exceeded retry limit') {
          $interesting++
          $runtime=''
          try {$runtime=(($e.GetRuntimeId()) -join '.')} catch {}
          Emit ("CONTROL|name={0}|control_type={1}|automation_id={2}|help_text={3}|item_status={4}|enabled={5}|offscreen={6}|rect={7}|runtime_id={8}" -f (Clean $c.Name),(Clean $ct),(Clean $c.AutomationId),(Clean $c.HelpText),(Clean $c.ItemStatus),$c.IsEnabled,$c.IsOffscreen,(RectText $c.BoundingRectangle),$runtime)
        }
      }
      Emit ("UIA_SUMMARY|count={0}|interesting={1}|types={2}" -f $all.Count,$interesting,(($types.Keys | Sort-Object | ForEach-Object {"$($_)=$($types[$_])"}) -join ','))
      if($interesting -eq 0) { Emit 'SIDEBAR_STATUS_NOT_EXPOSED|No tested failure marker or sidebar session identity was exposed by standard Windows UIA.' }
    }

    if($Mode -eq 'scan') {
      $rows=0;$failed=0;$walker=[System.Windows.Automation.TreeWalker]::ControlViewWalker
      $script:scanSeen=@{}
      function VisitNode($node,[string]$projectName) {
        $c=$node.Current;$nextProject=$projectName
        if($c.ControlType -eq [System.Windows.Automation.ControlType]::Group -and $c.Name -and $c.Name -notmatch '中的'){$nextProject=Clean $c.Name}
        if($c.ControlType -eq [System.Windows.Automation.ControlType]::ListItem) {
          $nested=$node.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty,[System.Windows.Automation.ControlType]::ListItem))
          if($nested.Count -eq 0) {
            $children=$node.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
            $sessionButton=$null;$marker=$null
            $rowTitle=Clean $c.Name
            if($rowTitle -match '^(Pin|Archive|置顶|归档)') { return }
            foreach($ch in $children){
              $cc=$ch.Current
              if($cc.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $cc.Name -eq $rowTitle){$sessionButton=$ch}
              if($failedNames -contains $cc.Name){$marker=$ch}
            }
            if($null -eq $sessionButton){
              foreach($ch in $children){
                $cc=$ch.Current
                if($cc.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $cc.Name -and $cc.Name -notmatch '^(Pin|Archive|置顶|归档)' -and $cc.Name -ne $nextProject -and $cc.Name -notmatch '(…|\\.\\.\\.)$'){$sessionButton=$ch}
              }
            }
            $sbr=$null
            if($sessionButton){$sbr=$sessionButton.Current.BoundingRectangle}
            $isAuxiliary=$sessionButton -and ($sessionButton.Current.Name -like 'Pin*' -or $sessionButton.Current.Name -like 'Archive*' -or $sessionButton.Current.Name -like '置顶*' -or $sessionButton.Current.Name -like '归档*')
            $isRowButton=$sessionButton -and ($sbr.Width -gt 100 -or $sbr.X -le ($c.BoundingRectangle.X+$c.BoundingRectangle.Width/2))
            if($sessionButton -and -not $isAuxiliary -and $marker -and -not $sessionButton.Current.IsOffscreen -and $isRowButton -and $sbr.Width -gt 4) {
              $key=(Clean $nextProject)+'/'+(Clean $sessionButton.Current.Name)
              if($script:scanSeen.ContainsKey($key)){ return }
              $script:scanSeen[$key]=$true
              $script:rows++;$script:failed++;$br=$sessionButton.Current.BoundingRectangle
              Emit ("SESSION|key={0}|project={1}|title={2}|status=FAILED_MARKER|row_rect={3}|button_rect={4}|button_name={5}|button_enabled={6}|offscreen={7}" -f $key,(Clean $nextProject),(Clean $sessionButton.Current.Name),(RectText $c.BoundingRectangle),(RectText $br),(Clean $sessionButton.Current.Name),$sessionButton.Current.IsEnabled,$sessionButton.Current.IsOffscreen)
            }
            return
          }
        }
        $child=$walker.GetFirstChild($node)
        while($null -ne $child){VisitNode $child $nextProject;$child=$walker.GetNextSibling($child)}
      }
      VisitNode $root ''
      if($true) {
        $markers=@($all | Where-Object { $failedNames -contains $_.Current.Name -and -not $_.Current.IsOffscreen })
        $sidebarRows=@($all | Where-Object {
          $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem -and
          -not $_.Current.IsOffscreen -and
          $_.Current.BoundingRectangle.X -lt ($root.Current.BoundingRectangle.X+$root.Current.BoundingRectangle.Width*0.30)
        })
        $seen=$script:scanSeen
        foreach($markerNode in $markers) {
          $mr=$markerNode.Current.BoundingRectangle
          $row=$sidebarRows | Where-Object {
            $rr=$_.Current.BoundingRectangle
            $mr.X -ge $rr.X -and $mr.Y -ge $rr.Y -and
            ($mr.X+$mr.Width) -le ($rr.X+$rr.Width) -and
            ($mr.Y+$mr.Height) -le ($rr.Y+$rr.Height)
          } | Sort-Object { $_.Current.BoundingRectangle.Width*$_.Current.BoundingRectangle.Height } | Select-Object -First 1
          if($null -eq $row){continue}
          $rowTitle=Clean $row.Current.Name
          if(!$rowTitle -or $rowTitle -match '^(Pin|Archive|置顶|归档)'){continue}
          $children=$row.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
          $sessionButton=$null
          foreach($ch in $children){if($ch.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $ch.Current.Name -eq $rowTitle){$sessionButton=$ch;break}}
          if($null -eq $sessionButton){
            foreach($ch in $children){
              $cc=$ch.Current;$cr=$cc.BoundingRectangle
              if($cc.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $cc.Name -and $cc.Name -notmatch '^(Pin|Archive|置顶|归档)' -and $cr.Width -gt 100 -and $cr.X -ge $row.Current.BoundingRectangle.X -and ($cr.X+$cr.Width) -le ($row.Current.BoundingRectangle.X+$row.Current.BoundingRectangle.Width)){$sessionButton=$ch;break}
            }
          }
          if($null -eq $sessionButton){continue}
          $br=$sessionButton.Current.BoundingRectangle
          if($sessionButton.Current.IsOffscreen -or $br.Width -le 4){continue}
          $actualTitle=Clean $sessionButton.Current.Name
          if(!$actualTitle -or $actualTitle -match '^(Pin|Archive|置顶|归档)'){continue}
          $project=''
          $parent=$walker.GetParent($row)
          while($null -ne $parent){
            $pc=$parent.Current
            if($pc.ControlType -eq [System.Windows.Automation.ControlType]::Group -and $pc.Name -and $pc.Name -notmatch '中的'){$project=Clean $pc.Name;break}
            $parent=$walker.GetParent($parent)
          }
          $key=$project+'/'+$actualTitle
          if($seen.ContainsKey($key)){continue}
          $seen[$key]=$true
          $script:rows++;$script:failed++
          Emit ("SESSION|key={0}|project={1}|title={2}|status=FAILED_MARKER|row_rect={3}|button_rect={4}|button_name={5}|button_enabled={6}|offscreen={7}" -f $key,$project,$actualTitle,(RectText $row.Current.BoundingRectangle), (RectText $br),$actualTitle,$sessionButton.Current.IsEnabled,$sessionButton.Current.IsOffscreen)
        }
      }
      Emit ("SCAN_SUMMARY|rows={0}|failed={1}|scope=standard_UIA_descendants_only" -f $rows,$failed)
      if($rows -eq 0) { Emit 'SIDEBAR_STATUS_NOT_EXPOSED|No session row with the tested Task failed child was exposed by standard Windows UIA.' }
    }

    if($Mode -eq 'sidebar-dump') {
      $leftLimit=$rc.BoundingRectangle.X+($rc.BoundingRectangle.Width*0.30)
      $items=@($all | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::ListItem -and
        -not $_.Current.IsOffscreen -and
        $_.Current.BoundingRectangle.X -lt $leftLimit
      })
      foreach($item in $items) {
        $ic=$item.Current;$ir=$ic.BoundingRectangle
        $rn=Clean $ic.Name
        if($rn.Length -gt 100){$rn=$rn.Substring(0,100)}
        Emit ("SIDEBAR_ROW|name={0}|control_type={1}|rect={2}|offscreen={3}" -f $rn,(Clean $ic.ControlType.ProgrammaticName),(RectText $ir),$ic.IsOffscreen)
        $children=$item.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
        foreach($child in $children) {
          $cc=$child.Current
          if($cc.ControlType -notin @([System.Windows.Automation.ControlType]::Image,[System.Windows.Automation.ControlType]::Text,[System.Windows.Automation.ControlType]::Button,[System.Windows.Automation.ControlType]::Custom)) {continue}
          $cr=$cc.BoundingRectangle
          if($cr.Width -le 0 -or $cr.Height -le 0){continue}
          $cn=Clean $cc.Name
          if($cn.Length -gt 100){$cn=$cn.Substring(0,100)}
          Emit ("SIDEBAR_CHILD|row={0}|name={1}|control_type={2}|automation_id={3}|help_text={4}|item_status={5}|enabled={6}|offscreen={7}|rect={8}" -f $rn,$cn,(Clean $cc.ControlType.ProgrammaticName),(Clean $cc.AutomationId),(Clean $cc.HelpText),(Clean $cc.ItemStatus),$cc.IsEnabled,$cc.IsOffscreen,(RectText $cr))
        }
      }
      Emit ("SIDEBAR_DUMP_SUMMARY|rows={0}|scope=visible_left_listitems" -f $items.Count)
    }

    if($Mode -eq 'invoke-session') {
      $rr=$root.Current.BoundingRectangle
      $limit=$rr.X+($rr.Width*0.28)
      $matches=@($all | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $_.Current.Name -eq $Title -and -not $_.Current.IsOffscreen -and $_.Current.BoundingRectangle.X -lt $limit })
      if($matches.Count -eq 1) {
        try {
          $ip=$matches[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
          $ip.Invoke()
          Emit 'RESULT|INVOKE_SESSION_SENT|UIA InvokePattern completed for the uniquely matched sidebar session button.'
        } catch { Emit ("RESULT|INVOKE_SESSION_FAILED|{0}" -f (Clean $_.Exception.Message)) }
      } elseif($matches.Count -eq 0) { Emit 'RESULT|INVOKE_SESSION_NOT_FOUND|No unique visible sidebar session button matched the title.' }
      else { Emit 'RESULT|INVOKE_SESSION_AMBIGUOUS|More than one visible sidebar session button matched the title.' }
    }

    if($Mode -eq 'invoke-retry') {
      $errors=@($all | Where-Object { $_.Current.Name -and $_.Current.Name -match 'Selected model is at capacity' })
      $buttons=@($all | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $retryNames -contains $_.Current.Name -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
      $best=$null;$bestDy=[double]::PositiveInfinity
      foreach($b in $buttons){$br=$b.Current.BoundingRectangle;$by=$br.Y+$br.Height/2;foreach($er in $errors){$erx=$er.Current.BoundingRectangle;$ey=$erx.Y+$erx.Height/2;$dy=[Math]::Abs($by-$ey);if($dy -le [Math]::Max(40,$br.Height*2) -and $br.X -gt $erx.X -and $dy -lt $bestDy){$best=$b;$bestDy=$dy}}}
      if($null -eq $best -and $buttons.Count -eq 1){$best=$buttons[0]}
      if($best){
        try {
          $ip=$best.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
          $r=$best.Current.BoundingRectangle
          $ip.Invoke()
          Emit ("RETRY|button={0}|screen_x={1}|screen_y={2}|rect={3}|state=UIA_INVOKE_SENT" -f (Clean $best.Current.Name),([int]($r.X+$r.Width/2)),([int]($r.Y+$r.Height/2)),(RectText $r))
        } catch { Emit ("RESULT|INVOKE_RETRY_FAILED|{0}" -f (Clean $_.Exception.Message)) }
      } elseif($errors.Count -gt 0){Emit 'RESULT|ERROR_WITHOUT_MATCHED_RETRY|Current error is visible but no enabled retry button was exposed.'}
      else{Emit 'RESULT|NO_RETRY_BUTTON|No enabled retry button was exposed by UIA.'}
    }

    if($Mode -in @('send-state','invoke-send')) {
      $rr=$root.Current.BoundingRectangle
      $placeholderNames=@(([string][char]0x548c+[char]0x20+[char]0x43+[char]0x6f+[char]0x64+[char]0x65+[char]0x78+[char]0x20+[char]0x4e00+[char]0x8d77+[char]0x5de5+[char]0x4f5c),'Work with Codex','Ask Codex',([string][char]0x5f00+[char]0x59cb+[char]0x8f93+[char]0x5165),([string][char]0x8f93+[char]0x5165+[char]0x6d88+[char]0x606f))
      $composer=@($all | Where-Object {
        $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and
        $_.Current.IsEnabled -and -not $_.Current.IsOffscreen -and
        $_.Current.BoundingRectangle.Y -gt ($rr.Y+$rr.Height*0.70)
      })
      $hasComposerContent=$false
      foreach($edit in $composer){
        $ec=$edit.Current;$value=''
        try {$vp=$edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern);$value=([string]$vp.Current.Value).Trim()} catch {}
        if(-not [string]::IsNullOrWhiteSpace($value) -and $placeholderNames -notcontains $value){$hasComposerContent=$true;break}
      }
      if($hasComposerContent){
        Emit 'RESULT|COMPOSER_HAS_CONTENT|Visible enabled composer contains user content; no send action is permitted.'
      }
      $errors=@($all | Where-Object { $_.Current.Name -and $_.Current.Name -match 'Selected model is at capacity' })
      $running=@($all | Where-Object { $stopNames -contains $_.Current.Name -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
      if($hasComposerContent){ }
      elseif($running.Count -gt 0){Emit 'RESULT|RUNNING_SIGNAL|A current stop control is visible; send fallback is skipped.'}
      else {
        $rr=$root.Current.BoundingRectangle
        $sendNames=@('Send','Continue',([string][char]0x53d1+[char]0x9001),([string][char]0x7ee7+[char]0x7eed))
        $excludedActionNames=@('Voice','Stop','Retry')+$voiceNames+$stopNames+$retryNames
        $actions=@($all | Where-Object {
          $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and
          $_.Current.IsEnabled -and -not $_.Current.IsOffscreen -and
          $_.Current.BoundingRectangle.Y -gt ($rr.Y+$rr.Height*0.70) -and
          $_.Current.BoundingRectangle.X -gt ($rr.X+$rr.Width*0.70) -and
          $excludedActionNames -notcontains $_.Current.Name
        })
        $voice=@($all | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $voiceNames -contains $_.Current.Name -and -not $_.Current.IsOffscreen })
        if($actions.Count -eq 1) {
          $a=$actions[0];$ar=$a.Current.BoundingRectangle
          $buttonName=Clean $a.Current.Name
          if(!$buttonName){$buttonName=Clean $a.Current.AutomationId;if(!$buttonName){$buttonName='unnamed_bottom_action'}}
          if($Mode -eq 'send-state') { Emit ("SEND_READY|button={0}|screen_x={1}|screen_y={2}|rect={3}|state=ENABLED_BOTTOM_ACTION" -f $buttonName,([int]($ar.X+$ar.Width/2)),([int]($ar.Y+$ar.Height/2)),(RectText $ar)) }
          else {
            try {$ip=$a.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern);$ip.Invoke();Emit ("SEND|button={0}|screen_x={1}|screen_y={2}|rect={3}|state=UIA_INVOKE_SENT" -f $buttonName,([int]($ar.X+$ar.Width/2)),([int]($ar.Y+$ar.Height/2)),(RectText $ar))}
            catch {Emit ("RESULT|INVOKE_SEND_FAILED|{0}" -f (Clean $_.Exception.Message))}
          }
        } elseif($voice.Count -gt 0){Emit 'RESULT|VOICE_ACTION|The composer exposes voice input, so no automatic send action is permitted.'}
        else{Emit 'RESULT|SEND_ACTION_NOT_EXPOSED|No unique enabled bottom retry action was exposed by UIA.'}
      }
    }

    if($Mode -eq 'current') {
      $running=@($all | Where-Object { $stopNames -contains $_.Current.Name -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
      if($running.Count -gt 0){Emit 'RESULT|RUNNING_SIGNAL|A current stop control is visible; retry is skipped.'}
      else {
      $errors=@($all | Where-Object { $_.Current.Name -and $_.Current.Name -match 'Selected model is at capacity' })
      $buttons=@($all | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $retryNames -contains $_.Current.Name -and $_.Current.IsEnabled -and -not $_.Current.IsOffscreen })
      $best=$null;$bestDy=[double]::PositiveInfinity;$bestError=''
      foreach($b in $buttons){$br=$b.Current.BoundingRectangle;$by=$br.Y+$br.Height/2;foreach($er in $errors){$erx=$er.Current.BoundingRectangle;$ey=$erx.Y+$erx.Height/2;$dy=[Math]::Abs($by-$ey);if($dy -le [Math]::Max(40,$br.Height*2) -and $br.X -gt $erx.X -and $dy -lt $bestDy){$best=$b;$bestDy=$dy;$bestError=Clean $er.Current.Name}}}
      if($null -eq $best -and $buttons.Count -eq 1){$best=$buttons[0]}
      if($best){$r=$best.Current.BoundingRectangle;Emit ("RETRY|error={0}|button={1}|screen_x={2}|screen_y={3}|rect={4}|state=VISIBLE_ENABLED_MATCHED" -f $bestError,(Clean $best.Current.Name),([int]($r.X+$r.Width/2)),([int]($r.Y+$r.Height/2)),(RectText $r))}
      elseif($buttons.Count -gt 1){Emit 'RESULT|RETRY_BUTTON_AMBIGUOUS|More than one enabled retry button was exposed by UIA.'}
      else{Emit 'RESULT|NO_RETRY_BUTTON|No enabled retry button was exposed by UIA.'}
      }
    }

    if($Mode -in @('locate','verify')) {
      $found=$false
      $rootRect=$root.Current.BoundingRectangle
      $mainX=$rootRect.X+($rootRect.Width*0.15)
      foreach($e in $all){$c=$e.Current;$n=Clean $c.Name;$r=$c.BoundingRectangle;if($Title -and $n -eq $Title -and -not $c.IsOffscreen -and $r.X -gt $mainX){$found=$true;Emit ("TITLE|name={0}|control_type={1}|selected={2}|enabled={3}|rect={4}" -f $n,(Clean $c.ControlType.ProgrammaticName),$c.IsSelected,$c.IsEnabled,(RectText $r))}}
      if($found){Emit 'RESULT|FOUND_TITLE|The requested title is exposed by UIA.'}else{Emit 'RESULT|NOT_CONFIRMED|Target session was not exposed by UIA; no click is permitted.'}
    }
  }
} catch {
  Emit ("RESULT|UIA_ERROR|{0}" -f (([string]$_.Exception.Message) -replace '[\r\n]+',' '))
}
if($OutFile){ [IO.File]::WriteAllLines($OutFile,$records,(New-Object Text.UTF8Encoding($false))) } else { $records }
