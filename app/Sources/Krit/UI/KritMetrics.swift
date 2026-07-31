import AppKit

/// The spacing and radius ruler, ported value-for-value from the reference app.
///
/// These are not derived or eyeballed: the reference ships them as literal
/// design tokens, and they are reproduced here with the same names so a spacing
/// question always has one answer instead of a judgement call at each call site.
///
///     const Wu = 8
///     const Qi = { modal: 20, panel: 20.5, card: 8, button: 6 }
///     const Ki = { cardPadY: 12, cardPadX: 14, cardGap: 10,
///                  headerGap: 6, controlGap: 10, labelGap: 4, rowPadY: 8 }
///
/// Anything laid out by hand with a number that is not in here is a spacing bug
/// waiting to be noticed.
enum KritMetrics {

    /// Base unit. The margin a floating panel keeps from the window edge.
    static let unit: CGFloat = 8

    // MARK: - Radius (`Qi`)

    enum Radius {
        static let modal: CGFloat = 20
        /// The floating side panel. The half point is deliberate in the source.
        static let panel: CGFloat = 20.5
        static let card: CGFloat = 10
        /// Small cells: an icon tile, a swatch well.
        static let cell: CGFloat = 7
        static let button: CGFloat = 6
    }

    // MARK: - Card interior (`Ki`)

    /// Vertical padding inside a section card.
    static let cardPadY: CGFloat = 12
    /// Horizontal padding inside a section card.
    static let cardPadX: CGFloat = 14
    /// Space between two stacked cards.
    static let cardGap: CGFloat = 10
    /// Between a section's caption and its content.
    static let headerGap: CGFloat = 6
    /// Between two controls in the same row.
    static let controlGap: CGFloat = 10
    /// Between a label and the value it describes.
    static let labelGap: CGFloat = 4
    /// Vertical padding of a settings row inside a card.
    static let rowPadY: CGFloat = 8

    // MARK: - The customise panel

    enum Panel {
        /// Width of the customise column.
        static let width: CGFloat = 250
        /// Inset of the panel from the window edges. The panel floats.
        static let margin: CGFloat = KritMetrics.unit
        /// Tab header: `padding: "14px 10px 10px 26px"`.
        static let headerInsets = NSEdgeInsets(top: 14, left: 26, bottom: 10, right: 10)
        /// Gap between tab titles.
        static let tabGap: CGFloat = 16
        /// Scrolling body: `padding: "12px 12px 24px"`.
        static let bodyInsets = NSEdgeInsets(top: 12, left: 12, bottom: 24, right: 12)
        /// Height of the gradient that fades content out at the bottom edge.
        static let fadeHeight: CGFloat = 44
    }

    // MARK: - Grids

    enum Grid {
        /// Colour swatches: ten across, 5pt apart.
        static let swatchColumns = 10
        static let swatchGap: CGFloat = 5
        /// Icon/thumbnail cells: four across, 4pt apart.
        static let cellColumns = 4
        static let cellGap: CGFloat = 4
        /// Pack tiles: two across, 8pt apart.
        static let packColumns = 2
        static let packGap: CGFloat = 8
    }

    // MARK: - Section caption

    /// `fontWeight: 600, letterSpacing: 0.6px, uppercase`, at 11pt.
    ///
    /// The reference ships this at 10; 11 is the owner's call, and it is the
    /// better one on macOS, where 10pt uppercase with positive tracking starts
    /// to read as texture rather than as a word.
    static let sectionCaptionSize: CGFloat = 11

    static func sectionCaption(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: sectionCaptionSize, weight: .semibold),
            .foregroundColor: KritColors.textTertiary,
            .kern: 0.6,
        ])
    }

    // MARK: - Badge

    /// A status pill: 20pt tall, 6pt radius, tinted fill with same-hue ink.
    ///
    /// The geometry is from the owner's cheatsheet; the colours are not. Its
    /// literal green (`#CAFACE` on `#15B042`) only ever means "success", so what
    /// carries over is the *pattern*: a wash of the hue behind ink of the same
    /// hue, which stays legible in both themes without a border.
    enum Badge {
        static let height: CGFloat = 20
        static let radius: CGFloat = 6
        static let insets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        static let fontSize: CGFloat = 10
        /// Alpha of the hue behind the label.
        static let fillAlpha: CGFloat = 0.16
    }
}
