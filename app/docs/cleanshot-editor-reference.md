# CleanShot editor — análise minuciosa das referências (4 screenshots, 2026-06-10)

Fonte de verdade da EXPERIÊNCIA que o editor do KRIT deve entregar. Extraído
frame a frame das capturas reais do CleanShot X enviadas pelo usuário.

## Anatomia da janela

```
┌─ titlebar integrada ──────────────────────────────────────────────────┐
│ ●●●  [crop][add][bg-toggle] │ [sel][rect][fill][ell][line][arrow]     │
│      [text][spot][count][pen][shapes] │ (•cor)(slider/contextual)     │
│                                          [Save as…] [Done(primário)]  │
├──────────────┬────────────────────────────────────────────────────────┤
│ SIDEBAR      │                                                        │
│ (embutida,   │                CANVAS                                  │
│  ~170pt)     │   imagem composta centrada, margem generosa            │
│              │   checkerboard quando background = None                │
├──────────────┴────────────────────────────────────────────────────────┤
│ [100% ▾]            [⠿ Drag me ⠿]              [↑][📌][⧉][☁]          │
└────────────────────────────────────────────────────────────────────────┘
```

## Sidebar — ordem e layout EXATOS

1. **Templates** (topo!): dropdown com o nome do template ("trueNetLab") +
   lixeira (deletar) + "+" (salvar atual). Some quando não há templates? (img 1
   e 2 não mostram; img 3 mostra; img 4 mostra "Presets…"). Sempre presente é ok.
2. **None** — botão de largura total.
3. **Gradients** — grid 5 col; seleção = anel; header com **"Show less ^"**
   (expansível: colapsado mostra 2 fileiras, expandido mostra todas).
4. **Wallpapers** — thumbs reais + tile **"+"** com borda tracejada (importar).
5. **Blurred** — no CleanShot: 3 variantes borradas do fundo corrente. No KRIT:
   o usuário pediu explicitamente TOGGLE "Blur background" (mantém o toggle).
6. **Plain color** — bolinhas em 2 fileiras.
7. **Padding** — slider largura total.
8. **Inset** (slider) **+ "Auto-balance"** (checkbox) LADO A LADO.
9. **Shadow + Corners** — DOIS sliders compactos LADO A LADO (2 colunas).
10. **Alignment** (grid 3×3 compacto) **+ Ratio** (popup "Auto/4:3/…") LADO A LADO.

Tom: labels pequenos (~11pt) secundários; controles compactos; seções com
~16-20pt de respiro; a sidebar lê como UMA coluna organizada, nada empilhado
desnecessariamente em largura total.

## Barra inferior (não existe no KRIT hoje — criar)

- Esquerda: **zoom dropdown** ("35%", "55%", "78%", "100%") — zoom do canvas.
- Centro: pill **"Drag me"** — arrasta o RESULTADO EDITADO como arquivo (mesmo
  NSDraggingSource + file-promise do overlay).
- Direita: 4 ações com ícone: **Share** (sheet), **Pin** (pinned window),
  **Copy**, **Save/Cloud**. No KRIT: Share, Pin, Copy, Save (coral).

## Outros detalhes observados

- Canvas mostra **checkerboard** sob o shot quando background = None (img 4).
- "Save as…" além do Done: export com NSSavePanel (formato/nome).
- O canvas abre já ENQUADRADO (zoom-to-fit %, mostrado no dropdown), nunca com
  scrollbar à vista.
- Janela acompanha a composição (R1 já implementado).
- Color dot + controle contextual (size/fonte) ficam na titlebar, logo após as
  ferramentas — nosso dock já faz equivalente.

## Mapa de execução (deltas KRIT)

| # | Delta | Onde |
|---|-------|------|
| E1 | Templates pro TOPO (dropdown + lixeira + +) | BackgroundSidebar |
| E2 | Gradients Show more/less (2 fileiras colapsado) | BackgroundSidebar |
| E3 | Inset+Auto-balance, Shadow+Corners, Alignment+Ratio em pares 2-col | BackgroundSidebar |
| E4 | Bottom bar: zoom dropdown + Drag me + Share/Pin/Copy/Save | AnnotationWindowController |
| E5 | Checkerboard sob o shot com background None | AnnotationCanvas |
| E6 | "Save as…" (NSSavePanel) ao lado do Save | AnnotationWindowController/Toolbar |
| E7 | Zoom-to-fit no open + dropdown de zoom sincronizado | AnnotationWindowController/Canvas |
