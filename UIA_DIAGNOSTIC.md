# Windows UIA diagnostic notes

This file records reusable UI Automation findings without storing project names,
conversation titles, local paths, or chat contents.

## Observed structure

The standalone client exposes a Windows UIA tree similar to:

```text
window -> navigation -> list -> project group -> session list item -> session button
                                                             └── failure image
```

The failure marker has been observed as an `Image` child with either the English
name `Task failed` or the Chinese name `任务未成功`. The session title is not
used as an error heuristic.

## Properties used

The bridge reads only the properties needed for matching and safe action:

- `Name`
- `ControlType`
- `AutomationId`
- `HelpText`
- `ItemStatus`
- `IsEnabled`
- `IsOffscreen`
- `BoundingRectangle`

`RuntimeId` is diagnostic only. It is not treated as a stable session ID.

The session row and button must expose a usable rectangle. Before every action,
the row is located again because sidebar ordering can change.

## Error and action checks

The current conversation area must expose the capacity error text before an
action is allowed. The retry button must be enabled, visible, and spatially
associated with that error area. When a retry button is not exposed, the bridge
can inspect the bottom action button state:

- an upward arrow corresponds to composer content and is skipped;
- a voice button corresponds to an empty composer without a retry action;
- a right-pointing action button can be invoked only when the capacity error is
  present, the composer is empty, and no running signal is visible.

The default composer placeholder is ignored after whitespace normalization.

## Coverage boundary

The implementation covers rows exposed by the current UIA tree. It does not
claim coverage of collapsed, virtualized, or unloaded projects. It does not use
hover, OCR, fixed-pixel color detection, foreground activation, or real mouse
and keyboard input.

When the live sidebar tree does not expose a failure marker, the local state
reader may provide a recent failed turn as a candidate. Session navigation,
current error verification, and action invocation still require UIA. Each
`thread_id + turn_id` is handled at most once per tool run.

## Diagnostic commands

```powershell
powershell -ExecutionPolicy Bypass -File .\diagnose.ps1 -Handle <HWND>
powershell -ExecutionPolicy Bypass -File .\UiaRetry.ps1 -Handle <HWND> -Mode sidebar-dump
```

Outputs should be kept local. Do not commit logs, complete chat text,
authentication data, or machine-specific project names.
