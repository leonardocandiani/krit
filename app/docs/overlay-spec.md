# Overlay & Responsiveness Spec (user-defined, 2026-06-10)

The user's exact CleanShot-grade behavior for the post-capture preview cards and
the editor window. Source of truth for the current wave. Verified via
UITestRunner scenarios + the user's live test.

## O1. Slide-down → standby (peek)
Dragging a card downward (clear downward gesture, threshold ~40pt) parks it in
standby: the card slides to the bottom edge of ITS screen leaving a small glass
handle (up-chevron) visible. Click/hover the handle restores with a spring.
Auto-dismiss pauses while in standby (irrelevant when timeout = never).

## O2. Stacking
Multiple captures stack vertically (newest at the bottom, near the corner; older
cards push UP toward the top of the screen), each card fully visible with an
8-12pt gap — never overlapping. The stack lives on the screen where each capture
was taken (or the currently selected screen). When the stack reaches the top of
the screen, oldest cards compress into the stack (scale down slightly) rather
than overflow.

## O3. Standby-all
One gesture/control sends ALL stacked cards to standby at once (a small control
on the stack or dragging any card down with ⌥). Restoring brings the stack back.

## O4. Drag-off-screen → delete
Dragging a card and releasing it past the monitor edge (any side except the
bottom-standby gesture) deletes THAT capture: slide+fade out animation, history
item removed, stack reflows.

## O5. Space → in-place zoom preview (NOT macOS Quick Look)
With the cursor over a card, Space toggles a FLUID in-place zoom: the card
itself springs up to a large preview (~70% of the screen, anchored from the
card's position — feels like the card zooming, CleanShot-style). Space/Esc/click
zooms back into the card. No QLPreviewPanel.

## R1. Window follows the composed image
When a background is enabled/changed (padding/inset/ratio/template), the editor
WINDOW animates to match the composed canvas size (clamped to the visible
screen frame), spring/easeOut ~0.25s — canvas and window always agree; no dead
letterbox, no scrollbars appearing because the window lagged the content.

## M1. Motion pass
Springs on card entrance/stack reflow/standby/restore/zoom (stiffness ~300,
damping 18-22); easeOut exits; Reduce Motion → crossfades. The tool must FEEL
fluid (CleanShot bar), not just be correct.

---

# Wave 2 — refinamentos do usuário (2026-06-10, pós-teste visual)

## O1' Slide-down = standby de TODOS
Arrastar QUALQUER card pra baixo manda a PILHA INTEIRA daquela tela pra standby
(agrupados), não só o card arrastado. O ⌥ deixa de ser necessário.

## O4' Delete lado-consciente + clipboard
O delete por arrasto SABE de que lado o stack mora (Settings.overlayOnLeft):
stack à esquerda → jogar mais pra ESQUERDA (pra fora da borda esquerda) deleta;
stack à direita → borda direita. Ao deletar, o print permanece no clipboard se
o auto-copy estiver ativo; toast discreto "Deleted — still in your clipboard".

## O5' Zoom menor e fechável sem hover
O zoom do Espaço está grande demais e só fecha com o mouse sobre a imagem.
Corrigir: alvo ~50% do visibleFrame (ou 2.5× o card, o menor); Espaço/Esc fecham
SEMPRE enquanto o zoom existe (monitor de teclado ativo, independente do mouse);
clicar fora também fecha.

## M1' Entrada animada + micro-feedback
O card NÃO aparece instantâneo ao capturar: desliza da borda com spring sutil
(~0.35s). Micro-animações: copy (pulse + check), delete (slide-out + fade),
standby (squash sutil ao descer).

## SP1 Mudança de tela/resolução
Observar NSApplication.didChangeScreenParametersNotification e reposicionar
stacks + alças de standby (redimensionar o sistema bugava o overlay).

## SZ1 Tamanho do preview nas Configurações
Settings.overlaySize (S/M/L) exposto na janela de Preferences e aplicado em
runtime aos cards.

# Wave 2 — editor shell (referência CleanShot, imagens do usuário)

## ES1 Sidebar INTEGRADA às bordas da janela
A sidebar de backgrounds é uma COLUNA da janela (da titlebar ao rodapé,
encostada na borda esquerda), não um painel glass flutuante descolado. Material
sutil, separador fino; abrir/fechar desliza a coluna e o canvas reflui junto.

## ES2 Espaçamentos consistentes
Grids uniformes (5 col, gap fixo), None row sem rótulo duplicado, respiros
iguais entre seções (o screenshot do usuário mostra gaps irregulares).

## ES3 Botão de backgrounds vira ÍCONE na toolbar
Como na referência: um ícone com estado ativo, não o botão de texto largo.

## ES4 Bottom bar com atalhos
Barra inferior da janela: zoom% (popup) à esquerda; pill "Drag me" central
(arrasta o resultado EDITADO como arquivo, com file promise); atalhos à direita:
Share, Pin, Copy, Save (coral). "Melhor distribuído", pedido explícito.

## ES5 Checkerboard quando background = None
## ES6 "Save as…" (NSSavePanel) além do Save
## ES7 Zoom-to-fit ao abrir + popup de zoom sincronizado
## ES8 Preferences avançadas
Expor: tamanho do preview (S/M/L), espessura padrão da seta, countdown,
webcam/clicks/keystrokes — "configurações mais avançadas e inteligentes".
