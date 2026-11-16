#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent
SetControlDelay -1

; Codex standalone desktop multi-session retry controller.
; Detection and primary actions are PowerShell UIA InvokePattern.
; ControlClick NA remains available as a separately testable coordinate path.
; Automatic monitoring stays resident and starts after a valid Codex bind.
; Foreground Codex is allowed because UIA InvokePattern does not move the
; real mouse or send keyboard input.

psFile := A_ScriptDir "\UiaRetry.ps1"
statePs := A_ScriptDir "\CodexStateReader.ps1"
logFile := A_ScriptDir "\retry.log"
cfg := A_ScriptDir "\settings.ini"
scanMs := ReadNumber("scan_seconds",5,1,60)*1000
cooldownMs := ReadNumber("cooldown_seconds",10,1,3600)*1000
maxMinute := ReadNumber("max_per_minute",6,1,60)
maxTotal := ReadNumber("max_per_session",200,1,10000)
verifyMs := ReadNumber("verify_seconds",6,2,30)*1000
targetHwnd:=0
targetPid:=0
autoEnabled:=ReadBool("auto_enabled",true)
paused:=false
busy:=false
totalAttempts:=0
lastAttempt:=0
attemptTimes:=[]
sessionState:=Map()
stateHandled:=Map()
noticeGui:=0
noticeAlpha:=0
if !FileExist(psFile) {
 MsgBox "缺少 UiaRetry.ps1。","Codex Auto Retry","Iconx"
 ExitApp()
}
if !FileExist(statePs) {
 MsgBox "缺少 CodexStateReader.ps1。","Codex Auto Retry","Iconx"
 ExitApp()
}
SetTimer AutoBindTimer, 1000
SetTimer ScanTimer, scanMs
TrayTip "常驻监测已启动；正在自动绑定 Codex。F10 可重新绑定，F9 探测，F7 单次处理，F6 开关，F8 暂停，Ctrl+Alt+Q 退出。","Codex Auto Retry"

; Read-only/one-shot verification entry point for local acceptance tests.
; It uses the same BindWindow() and OneShot() path as the hotkeys.
if A_Args.Length && A_Args[1] = "--oneshot-active" {
 BindWindow()
 Sleep 300
 OneShot()
 ExitApp()
}
if A_Args.Length && A_Args[1] = "--notice-test" {
 ShowNotice("TEST","通知气泡测试")
 Sleep 1200
 SetTimer NoticeFade,40
 Sleep 500
 ExitApp()
}

^!F10::BindWindow()
^!F9::Probe()
^!F7::OneShot()
^!F6::ToggleAuto()
^!F8::PauseAuto()
^!q::ExitApp()

BindWindow(){
 global targetHwnd,targetPid,autoEnabled,paused,totalAttempts,lastAttempt,attemptTimes,sessionState
 ; Do not trust the active child Pane. The desktop app exposes several
 ; ChatGPT.exe top-level HWNDs; bind the largest visible main surface.
 hwnd:=FindCodexWindow()
 if !hwnd {
  MsgBox "未找到可见的 Codex 独立桌面窗口。","绑定失败","Icon!"
  return
 }
 BindHwnd(hwnd,false)
}

AutoBindTimer(){
 global targetHwnd,targetPid
 if ValidTarget()
  return
 hwnd:=FindCodexWindow()
 if hwnd
  BindHwnd(hwnd,true)
}

BindHwnd(hwnd,automatic){
 global targetHwnd,targetPid,autoEnabled,paused,totalAttempts,lastAttempt,attemptTimes,sessionState,stateHandled
 if !IsCodex(hwnd)
  return
 targetHwnd:=hwnd
 targetPid:=WinGetPID("ahk_id " hwnd)
 autoEnabled:=ReadBool("auto_enabled",true)
 paused:=false
 totalAttempts:=0
 lastAttempt:=0
 attemptTimes:=[]
 sessionState:=Map()
 stateHandled:=Map()
 Log((automatic ? "AUTO_BIND" : "BIND") "|pid=" targetPid "|hwnd=" targetHwnd)
 TrayTip autoEnabled ? "已自动绑定 Codex；5秒常驻监测已开启，单会话冷却10秒。" : "已绑定 Codex；自动监测关闭。","Codex Auto Retry"
}

FindCodexWindow(){
 windows:=WinGetList("ahk_exe ChatGPT.exe")
 best:=0
 bestArea:=0
 for _,hwnd in windows {
  if !IsCodex(hwnd)
   continue
  try {
   WinGetPos ,,&w,&h,"ahk_id " hwnd
  } catch {
   continue
  }
  if w<600||h<400
   continue
  area:=w*h
  if area>bestArea {
   best:=hwnd
   bestArea:=area
  }
 }
 return best
}

Probe(){
 global busy
 if busy||!ValidTarget() {
  TrayTip "先用 Ctrl+Alt+F10 绑定 Codex。","Codex Auto Retry"
  return
 }
 busy:=true
 try {
   out:=RunUIA("probe")
   FileAppend out Chr(10), A_ScriptDir "\probe.log","UTF-8"
   MsgBox out,"UIA 只读探测"
 } finally busy:=false
}

OneShot(){
 global busy
 if busy||!ValidTarget() {
  TrayTip "没有有效的 Codex 绑定。","Codex Auto Retry"
  return
 }
 busy:=true
 try {
   ok:=ProcessOne(true)
   TrayTip ok ? "已完成单次流程，详见 retry.log。" : "单次流程未执行或被跳过。","Codex Auto Retry"
 } finally {
   busy:=false
 }
}

ToggleAuto(){
 global autoEnabled,paused,totalAttempts,maxTotal
 if !ValidTarget() {
  TrayTip "先绑定 Codex。","Codex Auto Retry"
  return
 }
 autoEnabled:=!autoEnabled
 paused:=false
 if autoEnabled&&totalAttempts>=maxTotal {
  autoEnabled:=false
  TrayTip "已达到累计重试上限。","Codex Auto Retry"
  return
 }
 TrayTip autoEnabled ? "自动模式已开启。" : "自动模式已关闭。","Codex Auto Retry"
}
PauseAuto(){
 global paused
 paused:=!paused
 TrayTip paused ? "已暂停。" : "已恢复。","Codex Auto Retry"
}

ScanTimer(){
 global autoEnabled,paused,busy,targetHwnd,sessionState,stateHandled
 if !autoEnabled||paused||busy||!ValidTarget()
   return
 busy:=true
 try {
   sessions:=ParseSessions(RunUIA("scan"))
   stateSessions:=sessions.Length?[]:ParseStateFailures(RunState())
   candidates:=MergeCandidates(sessions,stateSessions,stateHandled)
   for _,s in candidates {
     if !sessionState.Has(s.key) {
       sessionState[s.key]:={project:s.project,title:s.title,last:0,tick:0,tries:0,result:"DETECTED"}
       Log("DETECTED|source=" s.source "|project=" s.project "|title=" s.title "|key=" s.key)
     }
   }
   for _,s in candidates {
     ProcessOne(false,s)
   }
 } finally busy:=false
}

ProcessOne(manual:=false,candidate:=0){
 global cooldownMs,maxMinute,maxTotal,totalAttempts,attemptTimes,sessionState,stateHandled,verifyMs,targetHwnd
 if !candidate {
   sessions:=ParseSessions(RunUIA("scan"))
   if !sessions.Length {
    return false
   }
   candidate:=sessions[1]
 }
 now:=A_TickCount
 if totalAttempts>=maxTotal {
  return false
 }
 while attemptTimes.Length&&now-attemptTimes[1]>=60000
   attemptTimes.RemoveAt(1)
 if attemptTimes.Length>=maxMinute {
  return false
 }
 latest:=ParseSessions(RunUIA("scan"))
 if candidate.source="state" {
  titleCount:=CountSessionTitle(latest,candidate.title)
  if titleCount>1 {
   MarkDeferred(candidate,"AMBIGUOUS_TITLE")
   Log("SKIP|ambiguous_sidebar_title|key=" candidate.key "|title=" candidate.title)
   return false
  }
  match:=titleCount=1?FindSessionByTitle(latest,candidate.title):candidate
 } else {
  match:=FindSession(latest,candidate.key)
 }
 if !match {
  Log("SKIP|ambiguous_or_not_visible|key=" candidate.key)
  return false
 }
 if sessionState.Has(match.key) {
  st:=sessionState[match.key]
  if st.tick && now-st.tick<cooldownMs {
   return false
  }
 }
 if match.source="state" && stateHandled.Has(match.key)
  return false
 if match.source="state"
  stateHandled[match.key]:=true
 nav:=RunUIA("invoke-session",match.title)
 if !InStr(nav,"INVOKE_SESSION_SENT") {
  MarkDeferred(match,"NAVIGATION_FAILED")
  Log("SKIP|session_navigation_invoke_failed|key=" match.key "|detail=" OneLine(nav))
  return false
 }
 Sleep 700
 if !SessionConfirmed(match.title) {
  MarkDeferred(match,"SESSION_NOT_CONFIRMED")
  Log("SKIP|session_not_confirmed|key=" match.key)
  return false
 }
 current:=RunUIA("current")
 sendState:=RunUIA("send-state")
 if InStr(current,"COMPOSER_HAS_CONTENT") || InStr(sendState,"COMPOSER_HAS_CONTENT") {
  MarkDeferred(match,"COMPOSER_HAS_CONTENT")
  if match.source="state"
   stateHandled[match.key]:=true
  ShowNotice(match.project,match.title,"检测到发送区已有内容，已跳过")
  Log("SKIP|composer_has_content|project=" match.project "|title=" match.title "|key=" match.key)
  return false
 }
 NoticeBeforeAction(match)
 retry:=ParseRetry(current)
 action:="retry"
 if retry {
  invokeResult:=RunUIA("invoke-retry")
  if !InStr(invokeResult,"RETRY|") {
   MarkDeferred(match,"RETRY_INVOKE_FAILED")
   Log("ERROR|retry_uia_invoke_failed|key=" match.key "|detail=" OneLine(invokeResult))
   return false
  }
 } else {
  if !InStr(sendState,"SEND_READY|") {
   MarkDeferred(match,"NO_SAFE_ACTION")
   Log("SKIP|no_retry_or_safe_send_action|key=" match.key "|detail=" OneLine(sendState))
   return false
  }
  invokeResult:=RunUIA("invoke-send")
  if !InStr(invokeResult,"SEND|") {
   Log("ERROR|send_button_uia_invoke_failed|key=" match.key "|detail=" OneLine(invokeResult))
   return false
  }
  action:="send_button"
 }
 totalAttempts++
 attemptTick:=A_TickCount
 attemptTimes.Push(attemptTick)
 if !sessionState.Has(match.key)
   sessionState[match.key]:={project:match.project,title:match.title,last:0,tick:0,tries:0,result:""}
 st:=sessionState[match.key]
 st.last:=A_Now
 st.tick:=attemptTick
 st.tries++
 st.result:="SENT"
 Log("SENT|action=" action "|project=" match.project "|title=" match.title "|key=" match.key "|attempt=" totalAttempts)
 result:=ObserveResult(verifyMs)
 st.result:=result
 if match.source="state"
  stateHandled[match.key]:=true
 Log("VERIFY|project=" match.project "|title=" match.title "|result=" result)
 return true
}

NoticeBeforeAction(match){
 global noticeGui
 ShowNotice(match.project,match.title)
 Log("NOTICE|project=" match.project "|title=" match.title "|delay_ms=300")
 Sleep 300
 SetTimer NoticeFade, 100
}

ShowNotice(project,title,reason:="发现异常会话"){
 global noticeGui,noticeAlpha
 if IsObject(noticeGui) {
  try {
   noticeGui.Destroy()
  }
  noticeGui:=0
 }
 noticeGui:=Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
 noticeGui.BackColor:="202124"
 noticeGui.SetFont("s10 cFFFFFF","Segoe UI")
 noticeGui.AddText("x14 y10 w360 h54", reason "`n" project " → " title)
 w:=390
 h:=78
 mon:=MonitorGetPrimary()
 MonitorGetWorkArea(mon,&left,&top,&right,&bottom)
 nx:=right-w-20
 ny:=bottom-h-20
 noticeAlpha:=255
 noticeGui.Show("x" nx " y" ny " NoActivate")
 WinSetTransparent(255,"ahk_id " noticeGui.Hwnd)
}

NoticeFade(){
 global noticeGui,noticeAlpha
 if !IsObject(noticeGui) {
  SetTimer NoticeFade,0
  return
 }
 noticeAlpha-=13
 if noticeAlpha<=0 {
  try {
   noticeGui.Destroy()
  }
  noticeGui:=0
  SetTimer NoticeFade,0
  return
 }
 WinSetTransparent(noticeAlpha,"ahk_id " noticeGui.Hwnd)
}

SessionConfirmed(title){
 return InStr(RunUIA("locate",title),"RESULT|FOUND_TITLE")>0
}
ObserveResult(timeout){
 start:=A_TickCount
 while A_TickCount-start<timeout {
   current:=RunUIA("current")
   if InStr(current,"RETRY|") {
    return "CAPACITY_AGAIN"
   }
   if InStr(current,"NO_CURRENT_CAPACITY") {
    return "EFFECT_NOT_CONFIRMED"
   }
   sendState:=RunUIA("send-state")
   if InStr(sendState,"RUNNING_SIGNAL") {
    return "RUNNING_OBSERVED"
   }
   if InStr(sendState,"NO_CURRENT_CAPACITY") {
    return "EFFECT_NOT_CONFIRMED"
   }
   Sleep 500
 }
 return "EFFECT_NOT_CONFIRMED"
}
ClickRect(rect){
 p:=StrSplit(rect,",")
 if p.Length<4||p[3]<4||p[4]<4 {
  return false
 }
 return ClickScreen(p[1]+p[3]/2,p[2]+p[4]/2)
}

OneLine(text){
 return RegExReplace(StrReplace(text,Chr(13)," "),"\s+"," ")
}
ClickScreen(x,y){
 global targetHwnd
 pt:=Buffer(8,0),NumPut("Int",x,pt,0),NumPut("Int",y,pt,4)
 if !DllCall("User32\ScreenToClient","Ptr",targetHwnd,"Ptr",pt,"Int") {
  return false
 }
 cx:=NumGet(pt,0,"Int"),cy:=NumGet(pt,4,"Int")
 try {
  ControlClick("X" cx " Y" cy,"ahk_id " targetHwnd,,"Left",1,"NA")
 } catch {
  return false
 }
 return true
}
ParseSessions(text){
 out:=[]
 for _,line in StrSplit(text,Chr(10)){
   p:=StrSplit(Trim(line),"|")
   if p.Length<2||p[1]!="SESSION" {
    continue
   }
   m:=Map()
   for i,v in p
      if i>1&&InStr(v,"=") {
       q:=StrSplit(v,"=",2)
       m[q[1]]:=q[2]
      }
   if m.Has("key")&&m.Has("title")&&m.Has("button_rect")&&m["button_rect"]!=""
     out.Push({key:m["key"],project:m.Get("project",""),title:m["title"],buttonRect:m["button_rect"],source:"uia"})
 }
 return out
}
ParseStateFailures(text){
 out:=[]
 for _,line in StrSplit(text,Chr(10)){
  p:=StrSplit(Trim(line),"|")
  if p.Length<2||p[1]!="STATE_FAILURE"
   continue
  m:=Map()
  for i,v in p
   if i>1&&InStr(v,"="){
    q:=StrSplit(v,"=",2),m[q[1]]:=q[2]
   }
  if m.Has("thread_id")&&m.Has("turn_id")&&m.Has("title")&&m["title"]!=""
   out.Push({key:"thread:" m["thread_id"] "/turn:" m["turn_id"],project:m.Get("project",""),title:m["title"],buttonRect:"",source:"state"})
 }
 return out
}
MergeCandidates(uia,state,handled){
 out:=[]
 seen:=Map()
 for _,s in uia {
   if !seen.Has(s.key){
    seen[s.key]:=true
    out.Push(s)
   }
 }
 for _,s in state {
   if !seen.Has(s.key)&&!handled.Has(s.key){
    seen[s.key]:=true
    out.Push(s)
   }
 }
 return out
}
ParseRetry(text){
 for _,line in StrSplit(text,Chr(10)){
   p:=StrSplit(Trim(line),"|")
   if p.Length<2||p[1]!="RETRY" {
    continue
   }
   m:=Map()
   for i,v in p
      if i>1&&InStr(v,"=") {
       q:=StrSplit(v,"=",2)
       m[q[1]]:=q[2]
      }
   if m.Has("screen_x")&&m.Has("screen_y") {
    return [m["screen_x"]+0,m["screen_y"]+0]
   }
 }
 return 0
}
FindSession(list,key){
 found:=0
 for _,s in list
   if s.key=key {
    if found
     return 0
    found:=s
   }
 return found
}
FindSessionByTitle(list,title){
 found:=0
 for _,s in list
  if s.title=title {
   if found
    return 0
   found:=s
  }
 return found
}
CountSessionTitle(list,title){
 count:=0
 for _,s in list
  if s.title=title
   count++
 return count
}
MarkDeferred(match,result){
 global sessionState
 if !sessionState.Has(match.key)
  sessionState[match.key]:={project:match.project,title:match.title,last:0,tick:0,tries:0,result:""}
 st:=sessionState[match.key]
 st.tick:=A_TickCount
 st.result:=result
}
RunUIA(mode,title:=""){
 global psFile,targetHwnd
 outFile:=A_Temp "\codex-auto-retry-" A_TickCount ".txt"
 ps:=A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
 safeTitle:=StrReplace(title,'"'," ")
 cmd:=Format('"{1}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{2}" -Handle {3} -Mode {4} -Title "{5}" -OutFile "{6}"',ps,psFile,targetHwnd,mode,safeTitle,outFile)
 try {
  RunWait(cmd,,"Hide")
 } catch {
  return "RESULT|PS_START_FAILED"
 }
 try {
  result:=FileRead(outFile,"UTF-8")
 } catch {
  result:="RESULT|PS_READ_FAILED"
 }
 try {
  FileDelete outFile
 }
 return result
}
RunState(){
 global statePs
 outFile:=A_Temp "\codex-auto-retry-state-" A_TickCount ".txt"
 ps:=A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
 cmd:=Format('"{1}" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{2}" -MaxAgeHours 24 -OutFile "{3}"',ps,statePs,outFile)
  try {
   RunWait(cmd,,"Hide")
  } catch {
   return "STATE_READER_START_FAILED"
  }
  try {
   result:=FileRead(outFile,"UTF-8")
  } catch {
   result:="STATE_READER_READ_FAILED"
  }
 try FileDelete outFile
 return result
}
IsCodex(hwnd){
 if !hwnd||!WinExist("ahk_id " hwnd) {
  return false
 }
 try {
  return StrLower(WinGetProcessName("ahk_id " hwnd))="chatgpt.exe"
 } catch {
  return false
 }
}
ValidTarget(){
 global targetHwnd,targetPid
 if !IsCodex(targetHwnd) {
  return false
 }
 ; A valid ChatGPT process is not sufficient: reject a child Pane or stale
 ; auxiliary surface when a larger visible main window is available.
 if FindCodexWindow()!=targetHwnd
  return false
 try {
  return WinGetPID("ahk_id " targetHwnd)=targetPid
 } catch {
  return false
 }
}
ReadNumber(key,def,min,max){
 global cfg
 try {
  v:=IniRead(cfg,"Limits",key,def)
 } catch {
  return def
 }
 return RegExMatch(v,"^\d+$")&&v+0>=min&&v+0<=max?v+0:def
}

ReadBool(key,def){
 global cfg
 try {
  v:=StrLower(Trim(IniRead(cfg,"Behavior",key,def?"true":"false")))
 } catch {
  return def
 }
 return v="1"||v="true"||v="yes"||v="on"
}
Log(s){
 global logFile
 try {
  FileAppend FormatTime(A_Now,"yyyy-MM-dd HH:mm:ss") " " s Chr(10),logFile,"UTF-8"
 }
}
