# Runtime bugs — live test findings (P1 evidence, user-observed)

Source of truth for the runtime-fix wave. These were observed by the user running
the real app on a live screen (2026-06-10). P1: if it was seen, it happened —
code that "looks correct" does not refute any of these.

| # | Bug | User report | Grounded evidence / hypothesis |
|---|-----|------------|--------------------------------|
| R1 | Selected element cannot be MOVED by dragging its body/center | "quando seleciono um elemento tenho que poder mudar ele de posição, arrastar pelo centro — hoje não temos" | AnnotationCanvas.mouseDown: marquee (B1) was added to the empty-canvas branch; body-drag-to-move either regressed or only stroke-band hit works, so center clicks fall through to marquee/deselect. |
| R2 | Apple wallpapers don't appear | "os wallpapers não estão aparecendo os da apple" | The Wallpapers grid with SystemWallpaperSource lives in the NEW BackgroundSidebar; but the toolbar "Background" button still opens the OLD BackgroundPopoverController (AnnotationWindowController:919, class at :942) with procedural presets only. Two parallel editors. |
| R3 | Sidebar controls (padding/inset/shadow/corners/alignment/ratio) broken & unprofessional | "totalmente desconexa da barra de cima... distorce as proporções, algumas funções nem funcionam, controles muito pequenos" | Same two-editor split: popover state and sidebar state are not the same options object end-to-end; canvas resize on options change distorts because window/canvas frame doesn't re-derive from composed output size; tiny `controlSize: .small` sliders. |
| R4 | Preview overlay: requested features don't work at runtime; no multi-monitor | "arrastar pra baixo (peek), preview maior no espaço, segundo monitor — zero funcionamento" | Features were implemented (code exists: toggleQuickLook, peek/park, cascade) but something in the REAL capture path prevents them: overlay window may never become key (keyDown/Space dead), drag handlers may conflict with thumb file-drag, and the overlay is placed on `NSScreen.main` instead of the screen where the capture happened. |
| R5 | Sounds don't play | "sons não tão tocando" | Settings.playSounds defaults to true, bundle Krit_Krit.bundle IS in the app — so the break is in resource resolution (custom `resourceBundle` probe paths) or SoundManager init/warm-up in the .app context. Must be reproduced with the real /Applications/KRIT.app binary. |
| R6 | Editor window: traffic lights overlap toolbar; not enough height for sidebar | screenshot shows close/min/max buttons overlapping the toolbar's left tool group | fullSizeContentView + centered contentStack: the 92pt trafficLightReservedWidth constant exists but the centered NSStackView ignores it at narrow widths; minimum window height doesn't account for the background sidebar. |
| R7 | Systematic sweep wanted | "vasculhamento inteligente para entender todas essas falhas core" | Run a core-flows sweep (capture → overlay → editor → annotate → background → export/copy/save → pin → history) and list every additional broken/unprofessional behavior found. |

## Fix rules for this wave
1. Root cause FIRST, with evidence (file:line + runtime repro where possible via
   the automation triggers / headless renders / defaults). No symptom patches.
2. The OLD BackgroundPopoverController path must be REMOVED (battle plan #8 note):
   the toolbar Background button opens the one true sidebar. One options object,
   one state flow: sidebar ⇄ canvas ⇄ export all read the same
   ScreenshotBackgroundOptions.
3. Editor window/canvas geometry derives from ScreenshotBackgroundComposer
   .outputPointSize (already exists) so proportions NEVER distort.
4. Overlay must be created on the capture's screen (pass the NSScreen through),
   and its interactive features must work without stealing focus from other apps.
5. swift build green + build-app.sh OK at the end of every fix; final visual
   sign-off is the user's live re-test.
