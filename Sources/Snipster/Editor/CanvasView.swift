import AppKit
import Carbon.HIToolbox

/// Everything undo needs to restore: the bitmap (cropping replaces it), what
/// is drawn on top, and what the result is dressed in.
struct EditorState {
    var image: PixelImage
    var annotations: [Annotation]
    var decoration = Decoration()
}

@MainActor
protocol CanvasViewDelegate: AnyObject {
    /// The image, annotations or selection changed.
    func canvasDidChange(_ canvas: CanvasView)
    /// The picture changed size (a crop, or padding and a frame around it).
    func canvasDidResize(_ canvas: CanvasView)
    func canvas(_ canvas: CanvasView, didRequest tool: Tool)
    func canvasDidRequestClose(_ canvas: CanvasView)
    func canvasDidRequestCopyAndClose(_ canvas: CanvasView)
}

/// The editing surface: draws the screenshot with its decoration and
/// annotations, and turns mouse and key input into edits.
///
/// Annotations live in image points with the origin at the screenshot's
/// top-left corner. A decoration moves the screenshot inside the view (padding,
/// title bar), so view coordinates are image coordinates plus `contentOrigin`.
final class CanvasView: NSView {
    weak var delegate: CanvasViewDelegate?

    private(set) var state: EditorState
    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private let cache = RedactionCache()
    private let decorationRenderer = DecorationRenderer()
    /// True while consecutive decoration tweaks share one undo step.
    private var isAdjustingDecoration = false

    var tool: Tool = .arrow {
        didSet {
            guard tool != oldValue else { return }
            commitText()
            cropRect = nil
            window?.invalidateCursorRects(for: self)
        }
    }
    /// Colour and stroke size for new annotations.
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 4

    private(set) var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            for id in [oldValue, selectedID] { invalidate(annotation(withID: id)) }
        }
    }
    private var draft: Annotation? {
        didSet {
            invalidate(oldValue)
            invalidate(draft)
        }
    }
    private var cropRect: CGRect? {
        didSet { needsDisplay = true }
    }

    private enum Drag {
        case none
        case creating(start: CGPoint)
        case moving(id: UUID, last: CGPoint, checkpointed: Bool)
        case resizing(id: UUID, handle: Int, checkpointed: Bool)
        case cropping(start: CGPoint)
    }
    private var drag = Drag.none

    private var textEditor: InlineTextEditor?
    /// The existing text annotation being edited (hidden while the editor is up).
    private var editingID: UUID?

    init(image: PixelImage, decoration: Decoration = Decoration()) {
        state = EditorState(image: image, annotations: [], decoration: decoration)
        super.init(frame: CGRect(origin: .zero, size: decoration.outerSize(for: image.size)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    /// Where the screenshot's top-left corner is in view coordinates.
    private var contentOrigin: CGPoint { state.decoration.contentOrigin }
    private var imageBounds: CGRect { CGRect(origin: .zero, size: state.image.size) }
    /// Size of the whole picture, decoration included, in points.
    var documentSize: CGSize { state.decoration.outerSize(for: state.image.size) }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x - contentOrigin.x, y: point.y - contentOrigin.y)
    }

    var selectedAnnotation: Annotation? { annotation(withID: selectedID) }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func annotation(withID id: UUID?) -> Annotation? {
        guard let id else { return nil }
        return state.annotations.first { $0.id == id }
    }

    // MARK: Edits

    /// Saves the current state so the next change can be undone.
    private func checkpoint() {
        isAdjustingDecoration = false
        undoStack.append(state)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func restore(_ newState: EditorState) {
        let oldSize = documentSize
        isAdjustingDecoration = false
        state = newState
        if selectedAnnotation == nil { selectedID = nil }
        if documentSize != oldSize {
            setFrameSize(documentSize)
            delegate?.canvasDidResize(self)
        }
        needsDisplay = true
        delegate?.canvasDidChange(self)
    }

    /// Changes the frame and backdrop. Tweaks made in a row (dragging a
    /// slider, trying backdrops) undo as one step, until `endDecorationAdjustment`
    /// or any other edit.
    func setDecoration(_ decoration: Decoration) {
        guard decoration != state.decoration else { return }
        commitText()
        if !isAdjustingDecoration {
            checkpoint()
            isAdjustingDecoration = true
        }
        let oldSize = documentSize
        state.decoration = decoration
        if documentSize != oldSize {
            setFrameSize(documentSize)
            delegate?.canvasDidResize(self)
        }
        needsDisplay = true
        delegate?.canvasDidChange(self)
    }

    func endDecorationAdjustment() {
        isAdjustingDecoration = false
    }

    @objc func undo(_ sender: Any?) {
        commitText()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        restore(previous)
    }

    @objc func redo(_ sender: Any?) {
        commitText()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        restore(next)
    }

    private func update(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        invalidate(state.annotations[index])
        change(&state.annotations[index])
        invalidate(state.annotations[index])
    }

    private func add(_ annotation: Annotation) {
        checkpoint()
        state.annotations.append(annotation)
        selectedID = annotation.id
        invalidate(annotation)
        delegate?.canvasDidChange(self)
    }

    @objc func delete(_ sender: Any?) {
        guard let selected = selectedAnnotation else { return }
        checkpoint()
        invalidate(selected)
        state.annotations.removeAll { $0.id == selected.id }
        selectedID = nil
        delegate?.canvasDidChange(self)
    }

    /// Applies a new colour and/or stroke size to the selected annotation.
    func restyleSelection(color: NSColor? = nil, lineWidth: CGFloat? = nil) {
        guard let selected = selectedAnnotation else { return }
        checkpoint()
        update(selected.id) {
            if let color { $0.color = color }
            if let lineWidth { $0.lineWidth = lineWidth }
        }
        delegate?.canvasDidChange(self)
    }

    private func applyCrop(_ rect: CGRect) {
        let image = state.image
        let pixels = PixelRect(rect, scale: image.scale).clamped(width: image.width, height: image.height)
        guard pixels.width >= 2, pixels.height >= 2 else { return }
        checkpoint()
        let origin = pixels.cgRect(scale: image.scale).origin
        let cropped = image.cropped(to: pixels)
        // Annotations may sit on the padding around the picture; keep those too.
        let reach = state.decoration.contentOrigin
        let bounds = CGRect(origin: .zero, size: cropped.size).insetBy(dx: -reach.x, dy: -reach.y)
        var annotations = state.annotations
        for index in annotations.indices { annotations[index].translate(dx: -origin.x, dy: -origin.y) }
        annotations.removeAll { !$0.dirtyRect.intersects(bounds) }
        selectedID = nil
        state = EditorState(image: cropped, annotations: annotations, decoration: state.decoration)
        setFrameSize(documentSize)
        needsDisplay = true
        delegate?.canvasDidResize(self)
        delegate?.canvasDidChange(self)
    }

    /// The screenshot with its decoration and every annotation burned in.
    func renderedImage() -> PixelImage {
        commitText()
        let image = state.image
        let decoration = state.decoration
        guard !state.annotations.isEmpty || !decoration.isEmpty else { return image }
        let annotations = state.annotations
        let renderer = annotationRenderer()
        return decorationRenderer.render(decoration, around: image) { context in
            for annotation in annotations { renderer.draw(annotation, in: context) }
        }
    }

    // MARK: Drawing

    private func annotationRenderer() -> AnnotationRenderer {
        AnnotationRenderer(image: state.image, cache: cache,
                           contentClip: decorationRenderer.contentClip(for: state.decoration, imageSize: state.image.size))
    }

    private func invalidate(_ annotation: Annotation?) {
        guard let annotation else { return }
        let handleMargin = 8 / magnification
        setNeedsDisplay(annotation.dirtyRect.insetBy(dx: -handleMargin, dy: -handleMargin)
            .offsetBy(dx: contentOrigin.x, dy: contentOrigin.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let image = state.image
        if !state.decoration.isOpaque(around: image) { drawCheckerboard(in: dirtyRect, context: context) }
        // Show real pixels when zoomed in, smooth scaling when zoomed out.
        decorationRenderer.draw(state.decoration, around: image, in: context,
                                interpolation: magnification >= 2 ? .none : .high)
        context.interpolationQuality = .high

        // Everything from here on is in image coordinates.
        let origin = contentOrigin
        let dirty = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        let renderer = annotationRenderer()
        for annotation in state.annotations where annotation.id != editingID && annotation.dirtyRect.intersects(dirty) {
            renderer.draw(annotation, in: context)
        }
        if let draft { renderer.draw(draft, in: context) }
        if let cropRect { drawCropOverlay(cropRect, in: context) }
        if let selected = selectedAnnotation, selected.id != editingID { drawSelection(of: selected, in: context) }
        context.restoreGState()
    }

    /// The usual grey squares that stand for "nothing here" under a picture
    /// with transparent parts. Only ever on screen, never in the result.
    private func drawCheckerboard(in rect: CGRect, context: CGContext) {
        let square: CGFloat = 8
        context.saveGState()
        context.clip(to: rect.intersection(bounds))
        context.setFillColor(NSColor(white: 0.5, alpha: 0.18).cgColor)
        let columns = Int((rect.minX / square).rounded(.down))...Int((rect.maxX / square).rounded(.up))
        let rows = Int((rect.minY / square).rounded(.down))...Int((rect.maxY / square).rounded(.up))
        for row in rows {
            for column in columns where (row + column) % 2 == 0 {
                context.fill(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
            }
        }
        context.restoreGState()
    }

    private func drawCropOverlay(_ rect: CGRect, in context: CGContext) {
        context.saveGState()
        context.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
        context.addRect(bounds.offsetBy(dx: -contentOrigin.x, dy: -contentOrigin.y))
        context.addRect(rect)
        context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1 / magnification)
        context.stroke(rect)
        context.restoreGState()
    }

    private func drawSelection(of annotation: Annotation, in context: CGContext) {
        let unit = 1 / magnification
        context.saveGState()
        if annotation.handles.isEmpty {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(unit)
            context.setLineDash(phase: 0, lengths: [4 * unit, 3 * unit])
            context.stroke(annotation.frame.insetBy(dx: -4 * unit, dy: -4 * unit))
        }
        for handle in annotation.handles {
            let box = CGRect(x: handle.x - 4.5 * unit, y: handle.y - 4.5 * unit, width: 9 * unit, height: 9 * unit)
            context.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.4).cgColor)
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: box)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1.5 * unit)
            context.strokeEllipse(in: box.insetBy(dx: 0.75 * unit, dy: 0.75 * unit))
        }
        context.restoreGState()
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: tool == .select ? .arrow : (tool == .text ? .iBeam : .crosshair))
    }

    // MARK: Hit testing

    private func topAnnotation(at point: CGPoint) -> Annotation? {
        let tolerance = 4 / magnification
        return state.annotations.last { $0.hitTest(point, tolerance: tolerance) }
    }

    private func handleIndex(at point: CGPoint, of annotation: Annotation) -> Int? {
        // Tighter while drawing, so a new shape can start right next to the last one.
        let reach = (tool == .select ? 7 : 5) / magnification
        return annotation.handles.firstIndex { hypot($0.x - point.x, $0.y - point.y) <= reach }
    }

    private func clampedToImage(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), imageBounds.width), y: min(max(point.y, 0), imageBounds.height))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let wasEditing = textEditor != nil
        window?.makeFirstResponder(self)
        commitText()
        // The click that ends text editing shouldn't also start something new.
        if wasEditing { return }

        let point = imagePoint(for: event)
        // A just-drawn shape stays selected, so its handles can be adjusted
        // without leaving the drawing tool. Moving it takes the select tool:
        // otherwise a new shape couldn't start on top of the previous one.
        if let selected = selectedAnnotation, let handle = handleIndex(at: point, of: selected) {
            drag = .resizing(id: selected.id, handle: handle, checkpointed: false)
            return
        }

        switch tool {
        case .select:
            guard let hit = topAnnotation(at: point) else {
                selectedID = nil
                delegate?.canvasDidChange(self)
                return
            }
            selectedID = hit.id
            delegate?.canvasDidChange(self)
            if event.clickCount >= 2, case .text = hit.shape {
                beginText(editing: hit)
            } else {
                drag = .moving(id: hit.id, last: point, checkpointed: false)
            }
        case .text:
            if let hit = topAnnotation(at: point), case .text = hit.shape {
                beginText(editing: hit)
            } else {
                beginText(at: point)
            }
        case .counter:
            let numbers = state.annotations.compactMap { annotation -> Int? in
                if case .counter(_, let number) = annotation.shape { return number }
                return nil
            }
            let counter = Annotation(shape: .counter(center: point, number: (numbers.max() ?? 0) + 1),
                                     color: color, lineWidth: lineWidth)
            add(counter)
            drag = .moving(id: counter.id, last: point, checkpointed: true)
        case .crop:
            let start = clampedToImage(point)
            cropRect = CGRect(origin: start, size: .zero)
            drag = .cropping(start: start)
        case .arrow, .line, .rectangle, .ellipse, .pen, .highlighter, .pixelate, .blur:
            selectedID = nil
            if let shape = shape(from: point, to: point, constrained: false) {
                draft = Annotation(shape: shape, color: color, lineWidth: lineWidth)
                drag = .creating(start: point)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = imagePoint(for: event)
        let constrained = event.modifierFlags.contains(.shift)
        switch drag {
        case .none:
            return
        case .creating(let start):
            if let shape = shape(from: start, to: point, constrained: constrained) { draft?.shape = shape }
        case .moving(let id, let last, let checkpointed):
            if !checkpointed { checkpoint() }
            update(id) { $0.translate(dx: point.x - last.x, dy: point.y - last.y) }
            drag = .moving(id: id, last: point, checkpointed: true)
        case .resizing(let id, let handle, let checkpointed):
            if !checkpointed { checkpoint() }
            var next = handle
            update(id) { annotation in
                annotation.moveHandle(handle, to: point)
                // Dragging a corner past its opposite swaps which corner is held.
                if annotation.handles.count == 4 {
                    next = annotation.handles.enumerated().min {
                        hypot($0.element.x - point.x, $0.element.y - point.y) < hypot($1.element.x - point.x, $1.element.y - point.y)
                    }?.offset ?? handle
                }
            }
            drag = .resizing(id: id, handle: next, checkpointed: true)
        case .cropping(let start):
            let end = clampedToImage(point)
            cropRect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = .none }
        switch drag {
        case .creating:
            let finished = draft
            draft = nil
            if let finished, !finished.isDegenerate { add(finished) }
        case .cropping:
            let rect = cropRect
            cropRect = nil
            if let rect, rect.width >= 4, rect.height >= 4 {
                applyCrop(rect)
                delegate?.canvas(self, didRequest: .select)
            }
        case .moving(_, _, let checkpointed), .resizing(_, _, let checkpointed):
            if checkpointed { delegate?.canvasDidChange(self) }
        case .none:
            break
        }
    }

    /// The shape the current tool makes when dragged from `start` to `end`.
    private func shape(from start: CGPoint, to end: CGPoint, constrained: Bool) -> Annotation.Shape? {
        var end = end
        var rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        if constrained {
            // Shift: lines snap to 45 degree steps, boxes become square.
            let angle = (atan2(end.y - start.y, end.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(end.x - start.x, end.y - start.y)
            end = CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
            let side = max(rect.width, rect.height)
            rect = CGRect(x: end.x < start.x ? start.x - side : start.x, y: end.y < start.y ? start.y - side : start.y,
                          width: side, height: side)
        }
        switch tool {
        case .arrow: return .arrow(from: start, to: end)
        case .line: return .line(from: start, to: end)
        case .rectangle: return .rectangle(rect)
        case .ellipse: return .ellipse(rect)
        case .highlighter: return .highlight(rect)
        case .pixelate: return .redact(rect, .pixelate)
        case .blur: return .redact(rect, .blur)
        case .pen:
            guard case .pen(var points)? = draft?.shape else { return .pen([start]) }
            if let last = points.last, hypot(last.x - end.x, last.y - end.y) >= 1 / magnification { points.append(end) }
            return .pen(points)
        case .select, .text, .counter, .crop:
            return nil
        }
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        let template = Annotation(shape: .text(origin: point, string: ""), color: color, lineWidth: lineWidth)
        selectedID = nil
        showTextEditor(for: template)
    }

    private func beginText(editing annotation: Annotation) {
        editingID = annotation.id
        invalidate(annotation)
        showTextEditor(for: annotation)
    }

    private func showTextEditor(for annotation: Annotation) {
        guard case .text(let origin, let string) = annotation.shape else { return }
        let editor = InlineTextEditor(annotation: annotation, string: string,
                                      origin: CGPoint(x: origin.x + contentOrigin.x, y: origin.y + contentOrigin.y))
        editor.onCommit = { [weak self] in
            guard let self else { return }
            self.commitText()
            self.window?.makeFirstResponder(self)
        }
        addSubview(editor)
        textEditor = editor
        window?.makeFirstResponder(editor)
    }

    /// Turns the text being typed into an annotation (or updates/removes the edited one).
    func commitText() {
        guard let editor = textEditor else { return }
        textEditor = nil
        let string = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = CGPoint(x: editor.frame.origin.x - contentOrigin.x, y: editor.frame.origin.y - contentOrigin.y)
        var template = editor.annotation
        editor.removeFromSuperview()

        if let id = editingID {
            editingID = nil
            guard let existing = annotation(withID: id) else { return }
            if string.isEmpty {
                selectedID = id
                delete(nil)
            } else if existing.shape != .text(origin: origin, string: string) {
                checkpoint()
                update(id) { $0.shape = .text(origin: origin, string: string) }
                delegate?.canvasDidChange(self)
            } else {
                invalidate(existing)
            }
        } else if !string.isEmpty {
            template.shape = .text(origin: origin, string: string)
            add(template)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            delete(nil)
        case kVK_Escape:
            if draft != nil || cropRect != nil {
                draft = nil
                cropRect = nil
                drag = .none
            } else if selectedID != nil {
                selectedID = nil
                delegate?.canvasDidChange(self)
            } else {
                delegate?.canvasDidRequestClose(self)
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            delegate?.canvasDidRequestCopyAndClose(self)
        case kVK_LeftArrow: nudgeSelection(dx: -step, dy: 0)
        case kVK_RightArrow: nudgeSelection(dx: step, dy: 0)
        case kVK_UpArrow: nudgeSelection(dx: 0, dy: -step)
        case kVK_DownArrow: nudgeSelection(dx: 0, dy: step)
        default:
            if modifiers.isEmpty, let key = event.charactersIgnoringModifiers?.lowercased(),
               let picked = Tool.allCases.first(where: { $0.shortcut == key }) {
                delegate?.canvas(self, didRequest: picked)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard let selected = selectedAnnotation else { return }
        checkpoint()
        update(selected.id) { $0.translate(dx: dx, dy: dy) }
        delegate?.canvasDidChange(self)
    }
}

extension CanvasView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)): canUndo
        case #selector(redo(_:)): canRedo
        case #selector(delete(_:)): selectedID != nil
        default: true
        }
    }
}

/// The text field that appears on the canvas while typing a text annotation.
/// Return commits, Shift-Return inserts a line break.
final class InlineTextEditor: NSTextView {
    let annotation: Annotation
    var onCommit: (() -> Void)?

    /// `origin` is where the text starts, in the canvas view's coordinates.
    init(annotation: Annotation, string: String, origin: CGPoint) {
        self.annotation = annotation
        let attributes = annotation.textAttributes
        let minimum = Annotation.textSize("", attributes: attributes)
        let container = NSTextContainer(size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        super.init(frame: CGRect(origin: origin, size: CGSize(width: max(minimum.width, 8), height: minimum.height)),
                   textContainer: container)
        // The view keeps only a weak reference to its storage.
        retainedStorage = storage

        isRichText = false
        drawsBackground = false
        allowsUndo = true
        textContainerInset = .zero
        isHorizontallyResizable = true
        isVerticallyResizable = true
        minSize = frame.size
        maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        typingAttributes = attributes
        insertionPointColor = annotation.color
        self.string = string
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        layer?.borderWidth = 1
        sizeToFit()
    }

    private var retainedStorage: NSTextStorage?

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func keyDown(with event: NSEvent) {
        let key = Int(event.keyCode)
        let isReturn = key == kVK_Return || key == kVK_ANSI_KeypadEnter
        if key == kVK_Escape || (isReturn && !event.modifierFlags.contains(.shift)) {
            onCommit?()
        } else {
            super.keyDown(with: event)
        }
    }
}
