# Initial UIA diagnostic

Date: 2026-11-05 (Asia/Shanghai)

## Window

- CUA identified the standalone client as ChatGPT.exe.
- The CUA window identifier observed during the read-only probe was 659604.
- The native Chromium window tree also exposed RootWebArea, but its ordinary
  Windows UIA descendants were much smaller than the CUA accessibility tree.
  This is a compatibility boundary, not evidence that the sidebar is empty.

## Observed accessibility structure

The CUA accessibility tree exposed:

navigation -> list -> project list item -> project group -> project chat list -> chat list item -> chat button

The observed project/session examples were:

- project CSFM
- session 执行 CSFM-P1 项目审计
- child graphic name Task failed
- project PhonOP
- child graphic name Task failed

The current chat was a different project, so this established that sidebar
discovery is possible in the client accessibility surface.

## Status evidence

Task failed is the tested status child. The session title itself is not used
as an error heuristic. The attached screenshot also shows the capacity text
in the current error area:

Selected model is at capacity. Please try a different model.

The PowerShell bridge records Name, ControlType, AutomationId, HelpText,
ItemStatus, IsEnabled, IsOffscreen, BoundingRectangle, and RuntimeId. It
returns SIDEBAR_STATUS_NOT_EXPOSED when standard Windows UIA does not expose
the required status marker or row identity.

On the visible primary window, the probe returned a Window/Document tree with
session ListItem and Button controls. For example, it observed
CSFM -> 执行 CSFM-P1 项目审计 and PhonOP -> 初始化 PhonOP M0 架构审计,
both with enabled, on-screen buttons and a sibling Image named Task failed.
AutomationId, HelpText, and ItemStatus were empty for these session controls;
RuntimeId and BoundingRectangle were available. RuntimeId is therefore used
only for diagnostics, never as a persistent session key.

## Logs

The installed client keeps logs under:

%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0\LocalCache\Local\Codex\Logs

Read-only inspection found structured capacity failures such as
ThreadMetadataGenerationService with the exact capacity message. Nearby log
records can include conversationId, threadId, and sometimes projectRoot.
These records are useful auxiliary evidence, but do not by themselves prove
that a sidebar row is currently failed or provide a safe clickable rectangle.

## Coverage boundary

The implementation is limited to rows exposed in the current UIA tree. It
does not claim coverage of collapsed, virtualized, or unloaded projects. It
does not hover, OCR, move the real mouse, activate Codex, or use a fixed
pixel fallback. The foreground window is allowed for the current UIA
InvokePattern path.

## Window binding recheck (2026-11-06)

The process currently exposes multiple `ChatGPT.exe` HWNDs in the same PID.
The visible `HWND 594824` is the large `ControlType.Window` surface
(`0,0,1920,1040`) and contains the sidebar UIA tree. `HWND 5899640` is a
smaller `ControlType.Pane` surface (`961,0,959,1080`) whose tree contains only
12 elements and no sidebar session identity. The AHK binder now ignores the
active child surface and selects the largest visible ChatGPT surface with a
usable rectangle. A valid target is rechecked against that same selection.

The direct read-only scan of `HWND 594824` on 2026-11-06 returned
`SCAN_SUMMARY|rows=0|failed=0` and `SIDEBAR_STATUS_NOT_EXPOSED`. This means the
current UIA snapshot did not expose a `Task failed` marker at that moment; it
is not evidence that the client has no visual marker, and it is not reported
as a successful scan.

## Local state evidence (2026-11-06)

The Codex user state contains a stronger non-visual signal. Read-only queries
of `%USERPROFILE%\\.codex\\thread_history_1.sqlite` found `thread_turns.status`
values of `failed` with `error_json.codexErrorInfo=serverOverloaded` and the
exact capacity message. The corresponding thread metadata is in
`%USERPROFILE%\\.codex\\state_5.sqlite` and provides the stable `thread_id`,
title, project ID, and working directory when available. The new
`CodexStateReader.ps1` reads only the latest turn per thread and emits bounded
metadata; it does not read rollout bodies or write either database.

This state signal is suitable for recent failure detection and deduplication.
The automatic loop applies a 24-hour age bound to avoid replaying old
historical failures after startup. The state signal does not by itself provide
a sidebar row rectangle or prove that a visible Retry button is currently
present, so UIA is still required before a UI action.

## Localized sidebar status verification (2026-11-06)

The current remote project sidebar exposes the failure marker as a child UIA
`Image` with `Name=任务未成功`, `IsOffscreen=False`, and a usable rectangle.
For example, the marker was observed inside the rows
`PhonOP -> 初始化 PhonOP M0 架构审计` and
`EDEN -> 读取文档并完成任务 EDENet 项目交接与 M2.1 开发任务...`.
The English `Task failed` name remains supported. The scanner now merges the
standard and nested-list-item traversals and de-duplicates by project/title.

The live run detected PhonOP first and EDEN second. Both session switches and
send/retry actions were sent through the UIA path. A later scan returned zero
visible failure rows, so the markers were no longer exposed after processing.

## Current acceptance result

On 2026-11-05, UIA InvokePattern successfully changed the current page to
`CSFM -> 执行 CSFM-P1 项目审计`. The same Windows UIA tree exposed the exact
capacity error text, but did not expose the visible `Retry` button as an
enabled Button in the PowerShell UIA enumeration. The bridge therefore
returned `CAPACITY_WITHOUT_MATCHED_RETRY` and sent no retry action. This is a
real limitation of the current provider path; it is not reported as a
successful retry.
