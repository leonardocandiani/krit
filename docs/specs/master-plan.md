# KRIT Master Plan v1 — A Grande Atualização

> Plano faseado para elevar o KRIT a um app de captura nativo Apple coeso e de primeira.
> Produzido por recon read-only de todo o codebase (160 arquivos, 42k linhas) + auditoria de
> design/fluxo/dores + síntese arquitetural, com curadoria final contra o crítico de completude.
> Status: PLANO. Nada implementado. Datado de 2026-06-25.

## Visão

Cinco pilares definem a atualização:

1. **Captura sem flash** em qualquer wallpaper (inclusive aerial em dark mode), pipeline de frame congelado consistente em todos os modos.
2. **Design system completo de 5 dimensões** (cor, material, raio, tipografia, espaço) com uma língua visual única em TODAS as telas. Hoje só existem 2,5 dimensões e o editor de vídeo fala outra língua.
3. **Editor unificado** que serve print e vídeo na mesma superfície. Hoje são dois editores que nunca se cruzam.
4. **Interação determinista** com qualquer número de overlays. Hoje, mais de um card = bugs de drag/foco/z-order.
5. **Feel de mola real** com continuidade entre superfícies, sem corte seco.

## Duas correções de premissa (decididas lendo o código)

**1. Target: manter macOS 13 + `if #available`, não subir para 14 puro.**
O recon leu `Package.swift:6` e `ChromeFactory.swift:17`: o repo está em `.macOS(.v13)`. A escolha anterior (subir para 14) funciona, mas o caminho técnico superior é **manter 13 e guardar as APIs novas (subject-lifting Vision, `.symbolEffect`, shaders Glur/Variablur) atrás de `if #available(macOS 14, *)`**. Você ganha o que há de novo no Sonoma+ sem dropar quem está no Ventura. Subir o target puro só se Glur/Variablur virarem requisito duro. Isso vira a fase F0 (decisão + ADR).

**2. Stack macOS revisado: Luminare e DockProgress saem; Defaults, Motion, FluidGradient e Vision entram.**
A recomendação inicial de stack mudou depois de ler o código:
- **Luminare: NÃO adotar.** É SwiftUI-only e traz uma terceira linguagem visual opinativa que brigaria com o `KritColors` + `ChromeFactory` que o app AppKit já tem. O unificador real é completar a camada de tokens própria (F2), não importar um design system de fora.
- **DockProgress: NÃO adotar.** O KRIT é `LSUIElement` (sem Dock tile); usar exigiria promover/reverter a activation policy só pra piscar no Dock. Progresso in-HUD/toast resolve melhor.
- **Pow: marginal.** É SwiftUI-only, alcança só as 4 telas SwiftUI; o Motion token nativo (F6.1) cobre mais com menos dependência.
- **Defaults (sindresorhus): SIM** (F2.7), mesmo autor do KeyboardShortcuts que já está na árvore.
- **Motion (b3ll): SIM, com ressalva** (F6.2 vira opcional/pós), AppKit-nativo, target 13.
- **FluidGradient (Cindori): SIM, só no vídeo** (F7 track pós), macOS 12+, não no compositor de screenshot.
- **Vision (`VNGenerateForegroundInstanceMaskRequest`): SIM, gated 14+** (F7 track pós).

## Coordenação crítica com a sessão #3 (working tree)

O working tree em `/Volumes/Sandrinho/OSS` (branch `fix/area-selection-aerial-flash`) tem trabalho NÃO commitado de outra sessão, modificando: **AllInOneController.swift, AreaSelectionWindow.swift, CaptureEngine.swift, SystemWallpaperSource.swift**. Parte da F1 já está meio-implementada por ela (frozen-frame, exclusão de Finder, fix do `DefaultDesktop.heic` light).

Regra dura: **a F1 inteira pertence a essa branch viva e é feita pela sessão que já mexe nesses arquivos, nunca em paralelo** (editar em paralelo destrói trabalho não-commitado). As fases que NÃO tocam esses arquivos (F2 parte, F3 overlay, F6 feel isolado, F8) podem começar antes, em branch própria a partir de `origin/main`.

## Como ler

Fases F0–F9, cada uma entregável e verificável sozinha em runtime real. Micro-fases numeradas com escopo, arquivos-alvo (`file:line`), critério de aceite, risco e esforço (P/M/G). A ordem de execução está em "Sequenciamento" no fim.

---

## F0 — Decisão de target + ADR

**Goal:** target fixado e documentado; auditoria confirma nenhuma API 14+ sem `#available`.
**Depende de:** nada. Barato, gateia F7.

- **F0.1 — Fixar deployment target** (P, risco baixo)
  Decisão: manter `.macOS(.v13)`, guardar APIs novas com `if #available(macOS 14, *)`. Registrar ADR.
  Arquivos: `app/Package.swift:6` (leitura), `app/Sources/Krit/UI/ChromeFactory.swift:17`, `docs/architecture.md` (ADR nova).
  Aceite: ADR escrita; grep confirma toda API 14+ atrás de `#available`.

---

## F1 — Captura sem flash (coordenada com a sessão #3)

**Goal:** captura de área/janela/fullscreen/scrolling com ZERO flash dark→light em wallpaper aerial (dark mode), pipeline de frame congelado consistente em todos os modos. Prova de runtime com print real.
**Depende de:** a branch `fix/area-selection-aerial-flash` ser commitada/mergeada primeiro.

> Nota de curadoria: o crítico confirmou que o fast path do frozen-frame está LITERALMENTE morto hoje (`finish()` esvazia `overlays` em `AreaSelectionWindow:222` antes da completion +0.08s ler `croppedFrozenImage:152-155`, caindo no re-grab vivo `CaptureEngine:172-174`). Boa parte do encanamento já está escrita no working tree, então os efforts abaixo são menores do que pareceriam num greenfield.

- **F1.1 — Fazer o fast path do frozen-frame disparar** (P, risco alto-coordenação)
  É ~1 linha de reordenação: ler `croppedFrozenImage` DENTRO de `finish()` antes de `tearDown()`, ou reter os CGImages congelados fora do array `overlays`. Eliminar o re-grab vivo.
  Arquivos: `AreaSelectionWindow.swift:128-134,152-155,219-226`, `CaptureEngine.swift:150-175`.
  Aceite: print de área sobre aerial dark sem flash; o ramo `croppedFrozenImage` retorna não-nil (instrumentar via `AreaSelectionDiag`/`uiTestPickDiag`).
  Coordenação: PERTENCE à branch viva da sessão #3.

- **F1.2 — Unificar hide-icons via exclusão de Finder em TODOS os modos** (M, risco médio)
  Rotear fullscreen, scrolling E os caminhos de GRAVAÇÃO pelo `captureContentFilter` de exclusão de Finder que já existe; aposentar o `hideDesktopIconsForCaptureIfNeeded`/cover-window (pinta wallpaper bundled errado pra aerial dark).
  Arquivos: `CaptureEngine.swift:318-333,628,811,844`, `DesktopIconsManager.swift:35-61`, `ScrollingCaptureController.swift`, `SystemWallpaperSource.swift:162-171`.
  Aceite: fullscreen, scrolling E gravação com hide-icons mostram o MESMO wallpaper da tela; cover-window removido do caminho.
  > Correção do crítico: o cover-window ainda é usado nos caminhos de gravação (`:628,:811,:844`), não só fullscreen/scrolling. Incluído aqui.

- **F1.3 — Endurecer detector de frame uniforme + clamp proporcional** (P, risco baixo)
  Distinguir surface vazia da SCK de conteúdo liso real (não derrubar backdrop/loupe nem pagar retry de stream em região lisa legítima); trocar o clamp por-eixo independente por fator único de escala.
  Arquivos: `CaptureEngine.swift:1234-1242,1252-1262,1308-1340`, `AreaSelectionWindow.swift:67`.
  Aceite: captura de região branca/preta sólida não cai em re-grab nem perde loupe; captura >16384px num eixo mantém aspect.

- **F1.4 — (Opcional) Frescor no mouse-up sem reintroduzir o flash** (M, risco médio)
  Re-grab no release com o MESMO filtro Finder-excluído enquanto o overlay dark ainda cobre a tela, compondo por baixo. Recupera conteúdo dinâmico (vídeo/relógio) perdido pelo frozen estático do hotkey.
  Arquivos: `CaptureEngine.swift:159-170`, `AreaSelectionWindow.swift:55-74`.
  Aceite: vídeo tocando durante a seleção aparece no frame do release, sem flash. Verificar 2x.

---

## F2 — Design system: tokens, Defaults e VideoEditor na língua do app

**Goal:** as 3 dimensões de token faltantes criadas (tipografia, espaço, política de accent), VideoEditor 100% coral+glass+tokens, escala de raio fechada, Settings em Defaults reativo. Verificável por grep.
**Depende de:** F0 (target) para os gates; independe da F1 nos arquivos.

- **F2.1 — KritType: escala tipográfica semântica** (G, risco baixo, mecânico)
  Enum espelhando `ChromeFactory.Radius`, 7-8 papéis (largeTitle/title/heading/bodyEmphasis/body/callout/caption/footnote + mono), cada um vendendo NSFont E SwiftUI Font. Ancorar em `preferredFont(forTextStyle:)` para ganhar Dynamic Type (hoje 0 ocorrências). Migrar call sites pelos tamanhos mais repetidos (11/12/13).
  Arquivos: `app/Sources/Krit/Utilities/KritType.swift` (nova) + call sites app-wide.
  Aceite: telas migradas sem `systemFont(ofSize:)`/`.system(size:)` cru; build limpo.

- **F2.2 — KritSpacing: grid 4pt global** (M, risco baixo)
  Promover o enum `Style` local do `BackgroundSidebar` a `KritSpacing` compartilhado (2/4/6/8/12/16/20/24).
  Arquivos: `app/Sources/Krit/Utilities/KritSpacing.swift` (nova), `BackgroundSidebar.swift:32-44` + paddings soltos.

- **F2.3 — Fechar a escala de raio** (M, risco baixo)
  Mapear literais 14/13/9/5/6/8/10 para os tokens existentes (18/16/12/11/6), usar `ChromeFactory.concentricRadius` em cantos aninhados.
  Arquivos: `ChromeFactory.swift:31-37`, `CaptureEngine.swift:2540`, `AnnotationWindowController.swift:120`, `HistoryPanelController.swift:459,951`, `RecordingHUDWindow.swift:259,296,331`, `QRCodeResultWindow.swift:62`, `RecordingResultWindow.swift:61`, `QuickAccessOverlay.swift:115`.

- **F2.4 — Política de accent + KritTheme bridge** (M, risco baixo)
  Regra: coral nas superfícies de marca; `controlAccentColor` nos controles de formulário; NUNCA os dois no mesmo painel. Corrigir vazamentos. `ViewModifier KritTheme()` na raiz de toda `NSHostingController`.
  Arquivos: `app/Sources/Krit/UI/KritTheme.swift` (nova), `ColorPickerPanel.swift:264`, `TextStylePanel.swift:99`, `PreferencesContent.swift:64`.

- **F2.5 — Portar o VideoEditor para a língua do app** (M, risco baixo, maior ganho/linha)
  `Color.accentColor` → `KritColors.accent`; `Color(white:)` → `KritColors.editorStageTop/canvasBackground` (já existem, sem uso); anéis de seleção branco → coral; envolver o host em `KritTheme()`.
  Arquivos: `VideoEditorWindow.swift:399,408,471,523,538,552-553,602`, `VideoEditorTimeline.swift:305,306,348,360,363,370`.
  Aceite: grep zero de `Color.accentColor`/`Color(white:)` em `VideoEditor/`; abrir o editor de vídeo não troca a identidade da marca.

- **F2.6 — Migrar Settings para Defaults** (G, risco médio)
  `Defaults.Keys` preservando o rawValue EXATO de cada chave (compat de dados); `@State+onChange` → `@Default` reativo; enums como `Defaults.Serializable`. Manter `Settings` como facade fina na transição.
  Arquivos: `app/Package.swift`, `Settings.swift:18-389`, `PreferencesContent.swift:72-200`.
  Aceite: app lê preferências já gravadas sem reset (testar upgrade com UserDefaults populado); Forms refletem mudança externa.
  Risco: zerar preferência se rawValue divergir. Verificar antes de remover o boilerplate.

---

## F3 — Multi-overlay: coordenador único

**Goal:** com N cards (testar com 4): hover/teclado/scroll/drag deterministas; nenhum card some atrás de outro ao arrastar; irmãos nunca ficam key-less nem se auto-fecham no gesto. Monitores de evento caem de **4N+2 para ~4 fixos**.
**Depende de:** nada (arquivos próprios do Overlay, independe da #3).

> Raiz da dor "mais de 1 overlay = bugado": cada card instala 4 monitores e reconstrói posse varrendo `NSApp.orderedWindows` por evento (`QuickAccessOverlay:489-555,669-681`). Funciona com 1, vira corrida O(N) com vários.

- **F3.1 — OverlayInteractionCoordinator único** (G, risco alto)
  Coordenador estático com 1 global + 1 local mouse + 1 keyDown + 1 scroll, que calcula o card topmost-owning UMA vez por evento. Estender ao PinnedWindow.
  Arquivos: `app/Sources/Krit/Overlay/OverlayInteractionCoordinator.swift` (nova), `QuickAccessOverlay.swift:489-555,178-190,669-681`, `PinnedWindow.swift:362-368`.
  Aceite: com 4 cards, ~4 monitores (não 4N+2); hover/Space/Cmd+C sempre no card sob o cursor. Runtime, não headless.

- **F3.2 — Z-order autoritativo no gesto + fonte única de posse** (M, risco médio)
  Elevar o card arrastado (`orderFront`) no início do drag; posse por índice/topmost explícito da stack em vez de `orderedWindows`; remover o fallback `return true` que abre dupla-posse.
  Arquivos: `QuickAccessOverlay.swift:917-944,960,1157-1214,665-681,1668-1682`.

- **F3.3 — Congelar a stack durante qualquer gesto** (M, risco baixo)
  Flag `isAnyGestureActive` que pausa o `dismissTimer` de TODOS os cards e re-sincroniza hover/foco de TODOS ao fim do gesto.
  Arquivos: `QuickAccessOverlay.swift:942,974-987,1088-1138`.

- **F3.4 — Foco de teclado por NSPanel non-activating (matar grabKey)** (G, risco alto)
  Migrar de `grabKey` (`.accessory` + `NSApp.activate` + 4 reativações atrasadas) para `NSPanel .nonactivatingPanel` + `becomesKeyOnlyIfNeeded`. Mata o thrash "works once then dead".
  Arquivos: `QuickAccessOverlay.swift:585-618,623-644`.

- **F3.5 — Deletar o caminho de drag morto** (P, risco baixo)
  Remover o override window-level `mouseDown/Dragged/Up` (nunca dispara sobre o corpo do card), mantendo só `handleThumbDrag`. Estado de gesto com um dono.
  Arquivos: `QuickAccessOverlay.swift:901-913,855-860,1157-1214`.

---

## F4 — Fluxo conectado de gravação: rotear record→editor, HUD honesto

**Goal:** do stop ao export, um caminho único e previsível: editor de vídeo alcançável da superfície pós-stop (inclusive com overlay OFF) e opcionalmente do HUD; trim/convert volta a um card; "Trim & Convert" honra dimensions/quality/audio; HUD sem botão desabilitado permanente.
**Depende de:** nada estrutural; F4.3/F4.6 tocam RecordingHUDWindow (hoje LIMPO no tree, ok).

> Dor central recording-editor-disconnect: a barra/HUD não tem caminho ao editor (só `stopHandler`/`togglePauseHandler`), o editor real só vem do card da bandeja atrás de `afterCaptureShowOverlay`, e os nomes mentem (`reopenResultWindow` abre o editor; `reopenLastResult` abre o result window).

- **F4.1 — Renomear entradas + corrigir comentário que mente** (P, risco baixo)
  `reopenResultWindow` → `openVideoEditor`; `reopenLastResult` → `reopenResultPanel`; corrigir o comentário do `editAction`. Rename mecânico.
  Arquivos: `RecordingEngine.swift:236,267`, `QuickAccessOverlay.swift:2709-2718`.

- **F4.2 — Entrada de editor na superfície pós-stop** (P, risco baixo)
  Botão primário "Edit..." no `RecordingResultWindow` chamando `openVideoEditor`. Fecha o buraco de overlay-OFF nunca chegar ao editor.
  Arquivos: `RecordingResultWindow.swift:89-131`, `RecordingEngine.swift:247-265`.

- **F4.3 — (Opcional) editHandler no HUD** (M, risco baixo)
  `editHandler` no `RecordingHUDWindow`: stop + abre o editor ao finalizar.
  Arquivos: `RecordingHUDWindow.swift`, `RecordingEngine.swift:150-151`.

- **F4.4 — Rotear trim/convert de volta por presentResult** (P, risco baixo)
  Ao fim do trim, setar `lastFinishedRecording` e chamar `presentResult`. Acaba com o arquivo órfão no Desktop.
  Arquivos: `RecordingEngine.swift:1002-1026,1051-1052`.

- **F4.5 — Fazer o "Trim & Convert" realmente converter** (M, risco médio)
  `VideoTrimPanel.handle` parar de descartar as `ConvertOptions`; engine honrar rescale (`AVMutableVideoComposition renderSize`) e áudio mono/mute (`AVAudioMix`) além do timeRange.
  Arquivos: `VideoTrimPanel.swift:704-714`, `RecordingEngine.swift:1008,1015`.
  Aceite: escolher 50%/mono produz output reescalado/mono real (verificar dimensões e canais do arquivo).

- **F4.6 — HUD restart/discard: implementar ou remover** (M, risco médio)
  Implementar `restartHandler`/`discardHandler` no engine e atribuí-los, OU remover os dois botões. Hoje renderizam permanentemente desabilitados (viola HIG).
  Arquivos: `RecordingHUDWindow.swift:12,15,113,120`, `RecordingEngine.swift:150-151`.

> F4.7 (colapsar as 3 superfícies pós-gravação) foi DOBRADA dentro da F5.2 por orientação do crítico (fazer e refazer o routing é churn). O colapso nasce no shell unificado.

---

## F5 — Editor unificado: um shell para print e vídeo

**Goal:** uma janela hospeda OU canvas de anotação (still) OU player+timeline (vídeo), compartilhando toolbar, background, bottom bar e export. "Edit screenshot" e "Edit recording" abrem o MESMO shell; anotar sobre frame de vídeo pausado fica possível.
**Depende de:** F2 (tokens) + F4 (routing limpo).

> Maior custo e maior risco de regressão do roadmap. Fatiar e validar incrementalmente sem quebrar o `AnnotationWindowController` nem o `VideoEditorWindow` atuais.

- **F5.1 — Unificar o modelo de background (still + vídeo)** (M, risco médio)
  Fundir `ScreenshotBackgroundOptions` e `VideoBackgroundOptions` num tipo só (hoje o vídeo forka a struct, drift garantido).
  Arquivos: `VideoEditorWindow.swift:15-25,55`, `ScreenshotBackgroundComposer.swift`.

- **F5.2 — Shell host com canvas comutável (absorve F4.7)** (G, risco alto)
  `openEditor(for: asset)` decide a superfície; `card.editAction` chama um único `openEditor`; o shell monta canvas de anotação OU player+timeline, com toolbar/bottom bar/export compartilhados. Dobra GIF/Trim/Convert no menu de export do shell; aposenta `RecordingResultWindow`/`VideoTrimWindow` como janelas standalone.
  Arquivos: `app/Sources/Krit/Editor/CaptureEditorShell.swift` (nova), `AnnotationWindowController.swift:140`, `VideoEditorWindow.swift:633`, `QuickAccessOverlay.swift:2708-2734`.

- **F5.3 — Anotação sobre frame de vídeo** (G, risco alto)
  Aplicar seta/blur/texto sobre frame pausado e levar ao export.
  Arquivos: `CaptureEditorShell.swift`, `AnnotationCanvas.swift`, `VideoEditor/*`.

- **F5.4 — Export unificado + autosave** (M, risco médio)
  Menu de export único (GIF/Trim/imagem/vídeo) reusando `ZoomComposer` e flatten. **Autosave/recuperação do trabalho em progresso** e migração de janelas de edição já abertas para o novo shell (correção do crítico: reescrita de shell sem rede de autosave arrisca perda de edição).
  Arquivos: `CaptureEditorShell.swift`, `AnnotationCanvas.swift:3105`, `VideoEditorWindow.swift:306`.

---

## F6 — Feel: Motion token + continuidade

**Goal:** token de movimento central; continuidade card→editor sem corte seco; superfícies herdadas (seleção de área, HUD, hovers) polidas; Reduce Motion respeitado em 100% das superfícies (inclui toast e ripples).
**Depende de:** F3 (overlay estável) antes de tocar o motor do overlay.

> Aplicar Motion nas superfícies isoladas ANTES de encostar no overlay.

- **F6.1 — Motion token central** (M, risco baixo)
  Enum `Motion` (snappy/gentle/bounce + Duration) devolvendo `CASpringAnimation`/timing calibrados, com Reduce Motion checado internamente. Aplicar primeiro em CaptureFlash, CountdownWindow, ToastWindow, Welcome, incluindo o guard que falta em toast e ripples.
  Arquivos: `app/Sources/Krit/UI/Motion.swift` (nova), `CaptureFlash.swift:213-259`, `CountdownWindow.swift:104-105`, `ToastWindow.swift:24-47`, `KeystrokeClickOverlay.swift:164-223`.

- **F6.2 — Zoom-morph contínuo card→editor** (M, risco médio)
  Voar um snapshot do thumbnail para a moldura onde o editor abre e revelar a janela sob o ghost no settle (estilo Photos/Markup), reusando o vocabulário de handoff do zoom-to-tray.
  Arquivos: `QuickAccessOverlay.swift:2516-2542,2708-2719`, `CaptureFlash.swift:213-259`.

- **F6.3 — Polir a seleção de área: fade no realce + ease no loupe** (M, risco médio)
  Highlight de janela via `CAShapeLayer` + `CABasicAnimation` (crossfade entre janelas); fade-in/out + leve escala no loupe.
  Arquivos: `AreaSelectionWindow.swift:502-544,581-677,895-935`.

- **F6.4 — Entrada/saída do HUD + hover real nos botões** (M, risco baixo)
  `show()`/`closeHUD()` com fade+spring (Motion token); `trackingArea`/`mouseEntered` nos botões do HUD com crossfade.
  Arquivos: `RecordingHUDWindow.swift:171-194,207-221,268-318`.

- **F6.5 — Crossfade nos hovers + padronizar press** (P, risco baixo)
  Animar a troca de background em hover (0.12-0.15s) em OverlayCornerButton, OverlayPillButton e cells da BackgroundSidebar; mesmo spring de press.
  Arquivos: `QuickAccessOverlay.swift:3257-3342`, `BackgroundSidebar.swift:1403-1436`.

> A lib de spring real (Motion/b3ll OU card layer-hosted) foi MOVIDA para o track pós-atualização: o crítico classificou como o item de maior risco e menor necessidade (empilha troca de motor de animação sobre a máquina de gesto recém-reescrita, pra polir um feel já funcional).

---

## F7 — Ferramentas que faltam (aparado)

**Goal:** completar ferramentas que o app já tem encanamento pra suportar. Apenas o que ataca dor/gap real fica na grande atualização; expansão de feature foi pro track pós.
**Depende de:** F2 (tokens).

- **F7.1 — Secure redact automático + força ajustável** (M, risco baixo-segurança)
  `applySmartRedact` criar redação com `.secureBlur` (mosaico irreversível) em vez de `PixelateAnnotation` recuperável; slider de força para blur (radius) e pixelate (scale), hoje fixos em 12/10.
  Arquivos: `AnnotationCanvas.swift:673-685,979-998,2454-2465`, `AnnotationObject.swift:636,680`.
  Aceite (endurecido pelo crítico): o EXPORT precisa rasterizar e DESCARTAR os pixels originais da região no arquivo salvo, no histórico de undo e em qualquer original embutido. **Verificação adversarial: tentar recuperar a região do arquivo final.** Trocar só a camada on-screen não basta.

- **F7.2 — EffectCacheKey com escala de saída (nitidez do export)** (M, risco médio)
  Incluir a escala de render no `EffectCacheKey` pra o blur/pixelate exportar na resolução nativa, não na escala da tela durante a edição.
  Arquivos: `AnnotationObject.swift:616-626`, `AnnotationCanvas.swift:946-1012,3105-3174`.
  Aceite: export Retina de captura editada num display 1x não deixa a faixa de redação suave (hoje é inferência, verificar em runtime).

- **F7.3 — Texto multilinha** (M, risco baixo)
  Trocar o `NSTextField` single-line inline por `NSTextView` aceitando Shift+Return, mantendo o WYSIWYG dos presets.
  Arquivos: `AnnotationCanvas.swift:2273-2329,3180`.

---

## F8 — Integrações & polish

**Goal:** first-run completo com wizard de permissões, versões de fonte única, App Intents descobríveis, scrolling premium, acessibilidade base, dívidas de harness limpas.
**Depende de:** F2.

- **F8.1 — Wizard de permissões unificado** (M, risco baixo, aditivo)
  Nova `PreferencesTab.permissions` com 4 linhas de status ao vivo (Screen Recording, Accessibility, Camera, Microphone) e botão Grant; estender o Welcome além de Screen Recording.
  Arquivos: `PreferencesWindowController.swift:8-17`, `PreferencesContent.swift`, `WelcomeWindowController.swift:263-315`, `PermissionsManager.swift`.

- **F8.2 — Versões de fonte única** (P, risco baixo)
  Ler `CFBundleShortVersionString` como fonte única; remover o fallback `0.15.4` do AboutForm e o `mcpServerVersion 0.1.0` do MCP.
  Arquivos: `PreferencesContent.swift:775`, `MCPServer.swift:24`, `release.sh`.

- **F8.3 — App Intents descobríveis no build SPM** (M, risco médio)
  Gerar `AppIntentsMetadata.bundle` no pipeline de release pra Shortcuts/Spotlight descobrirem os intents fora do Xcode.
  Arquivos: `KritIntents.swift:10-16`, `release.sh`.

- **F8.4 — Acessibilidade base (correção do crítico)** (M, risco baixo)
  Rótulos VoiceOver (`NSAccessibility`) e navegação por teclado no overlay de captura, HUD e cards do QuickAccessOverlay; auditoria de contraste no editor unificado. Faz parte do "nativo Apple de primeira".
  Arquivos: superfícies de `Overlay/`, `Capture/`, `Editor/`.

- **F8.5 — Scrolling capture premium** (G, risco médio)
  Seam por correlação de fase (não SAD bruto), detecção de direção (vertical/horizontal), barra de progresso do stitch, aviso ao bater o cap de 300 frames.
  Arquivos: `ScrollingCaptureController.swift:77-82,235-291`.

- **F8.6 — Limpar dívidas de harness** (P, risco baixo)
  KVO cirúrgico na chave `showMenuBarIcon` (em vez do observer global); de-duplicar `appKitRect(fromTopLeft:)`; centralizar activation policy.
  Arquivos: `AppDelegate.swift:239-244,187-193`, `AutomationService.swift:181-187`, `ActivationPolicy.swift`.

---

## F9 — Verificação & regressão (gate transversal, exigido pelo crítico)

**Goal:** travar regressão nos subsistemas frágeis com os hooks de teste que já existem.
**Depende de:** roda como gate de fechamento de F1, F3 e F6.

- **F9.1 — Gate de regressão do frozen-frame** (M, risco baixo)
  Via `simulateSelection`/`uiTestPickDiag`/`AreaSelectionDiag`: travar que o ramo `croppedFrozenImage` retorna não-nil e que não há flash em aerial dark.
- **F9.2 — Protocolo manual de aceite multi-card e feel** (P, risco baixo)
  Roteiro fixo com 4+ cards (delete/park/conveyor/zoom) e checklist de feel, dado que o crítico admite que essa área "não se prova headless".

---

## Stack macOS final (curado)

| Lib / API | Adotar? | Onde | Fase |
|---|---|---|---|
| sindresorhus/Defaults | **Sim** | substituir o boilerplate do Settings.swift, prefs reativas | F2.6 |
| b3ll/Motion | Token nativo primeiro; lib só se preciso | spring real do overlay (alto risco) | pós-atualização |
| Cindori/FluidGradient | **Sim, só vídeo** | background animado do editor de vídeo | pós-atualização |
| Vision (ForegroundInstanceMask) | **Sim, gated 14+** | subject-lifting no editor | pós-atualização |
| Glur / Variablur | Só atrás de `#available(14)` | blur progressivo (scrim, foco) | opcional |
| Luminare | **Não** | brigaria com KritColors+ChromeFactory | — |
| DockProgress | **Não** | app é LSUIElement | — |
| Pow | Marginal | só as 4 telas SwiftUI | — |

## Track pós-atualização (fora do escopo da grande atualização)

Movido para cá por ser expansão de feature, não fix/unificação (anti-gold-plating, por orientação do crítico):

- Subject-lifting (Vision, gated 14+) + spotlight (portrait de fundo).
- Before/after da edição (slider de cortina).
- Background de gradiente animado no vídeo (FluidGradient).
- Lib de spring real (Motion/b3ll) ou card layer-hosted (o item de maior risco do feel).

## Sequenciamento

1. **F0** isolado e barato (decisão de target + ADR), gateia F7.
2. **F1** só depois da branch `fix/area-selection-aerial-flash` ser commitada/mergeada, feita pela sessão #3. F1.1 é ~1 linha; nunca editar em paralelo.
3. Em paralelo à #3, começar **F2** (design system, não toca os arquivos da #3) e **F3** (overlay, arquivos próprios) em branch própria a partir de `origin/main`.
4. **F4** (routing de gravação) destrava record→editor com mudanças cirúrgicas antes da fusão grande.
5. **F5** (editor unificado) depois de F2 (tokens) e F4 (routing). Maior risco, fatiar incremental.
6. **F6** (feel) depois de F3 estável.
7. **F7** (ferramentas) depois de F2.
8. **F8** (integrações) aditivo, baixo risco.
9. **F9** roda como gate de fechamento de F1, F3 e F6.

## Riscos (corrigidos contra o working tree real)

1. **Colisão de working tree:** a #3 modifica AllInOneController, AreaSelectionWindow, CaptureEngine, SystemWallpaperSource (todos alvos de F1). Mitigação: F1 só depois do merge da #3; nunca editar em paralelo; isolamento por worktree se houver concorrência.
2. **Target:** manter 13 + `#available` (F0); subir para 14 só se Glur/Variablur virarem requisito.
3. **Áreas que não se provam headless:** coordenador de overlay (F3.1), foco non-activating (F3.4). Verificar em runtime com 4+ cards, gesto a gesto.
4. **F5 funde AppKit + SwiftUI:** maior risco de regressão. Fatiar F5.1→F5.4, validar cada fatia.
5. **Settings→Defaults (F2.6):** pode zerar preferência se rawValue divergir. Preservar cada string de chave; testar upgrade.
6. **Redact (F7.1):** segurança. Verificação adversarial obrigatória (tentar recuperar a região do export).
