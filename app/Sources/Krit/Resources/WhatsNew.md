version: 0.31.0
KRIT 0.31.0 rebuilds the screenshot editor and puts every screen on one visual system.

## The editor

The command band and the bottom bar are now floating glass capsules over a stage that runs the full height of the window, and the background sidebar is a floating panel rather than a column welded to the edge. The panel stops clear of the traffic lights, so the close and zoom buttons are never buried under its content.

Glass is real glass: a top highlight, an inner rim, a contact shadow and a lift shadow, instead of a flat translucent fill. How translucent it gets is now yours to set, in Settings under Editor, Appearance.

## One ruler for the whole app

KRIT was carrying two competing radius scales. Screens built at different times ended up with corners 4pt apart, which is enough for the eye to catch even when it cannot name what is wrong. Every surface now derives from the same spacing and radius tokens.

The recording bars, the preview card and the Quick Look preview also drop their single heavy shadow for the shared one. The old shadow was dark enough to read as a filter painted under a rectangle; over pale content it looked like a smudge.

## Fixes

A preview card could open the whole editor when you did nothing but move the cursor across it. Hovering a card activates KRIT so Space and the shortcut keys work without a click, and a Cmd+E already in flight toward another app was landing on the card. Keystrokes that arrive in the first fraction of a second after the card takes focus are now ignored.

Dragging a slider in Settings dragged the entire window instead of the slider.

A selected tool in the toolbar turned solid white, hiding the icon of the tool you had just picked.
