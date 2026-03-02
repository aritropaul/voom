import SwiftUI
import AVKit

struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer
    @Binding var wrapper: _PlayerWrapper?
    var chapters: [Chapter] = []

    func makeNSView(context: Context) -> _PlayerWrapper {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.allowsPictureInPicturePlayback = true
        playerView.player = player

        let w = _PlayerWrapper(playerView: playerView)
        DispatchQueue.main.async { wrapper = w }
        return w
    }

    func updateNSView(_ nsView: _PlayerWrapper, context: Context) {
        nsView.playerView.player = player
        nsView.updateChapterMarkers(chapters: chapters, duration: player.currentItem?.duration.seconds ?? 0)
    }
}

final class _PlayerWrapper: NSView {
    let playerView: AVPlayerView
    private var captionLabel: NSTextField?
    private var captionBottomConstraint: NSLayoutConstraint?
    private var currentCaptionText: String?

    init(playerView: AVPlayerView) {
        self.playerView = playerView
        super.init(frame: .zero)
        playerView.autoresizingMask = [.width, .height]
        addSubview(playerView)

        NotificationCenter.default.addObserver(
            self, selector: #selector(fullscreenChanged),
            name: NSWindow.didEnterFullScreenNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(fullscreenChanged),
            name: NSWindow.didExitFullScreenNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func fullscreenChanged() {
        refreshCaptionFont()
    }

    // Prevent AVPlayerView / caption label from pushing SwiftUI layout
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override func layout() {
        super.layout()
        playerView.frame = bounds
        // Detect fullscreen changes (AVPlayerView moves to a new window)
        let fs = isFullScreen
        if fs != lastFullScreenState {
            lastFullScreenState = fs
            refreshCaptionFont()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let fs = isFullScreen
        if fs != lastFullScreenState {
            lastFullScreenState = fs
            refreshCaptionFont()
        }
    }

    override func invalidateIntrinsicContentSize() {
        // Block — don't let subview changes propagate up
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    private var isFullScreen: Bool {
        // When AVPlayerView enters fullscreen, contentOverlayView (and our caption label)
        // moves to a NEW fullscreen window. Check if the label's window differs from ours.
        if let labelWindow = captionLabel?.window, let myWindow = self.window, labelWindow != myWindow {
            return true
        }
        return playerView.isInFullScreenMode ||
            playerView.window?.styleMask.contains(.fullScreen) == true
    }
    private var lastFullScreenState = false

    private var captionFontSize: CGFloat {
        isFullScreen ? 24 : 14
    }

    private func refreshCaptionFont() {
        guard let label = captionLabel, let text = currentCaptionText, !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: captionFontSize, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ])
        captionBottomConstraint?.constant = isFullScreen ? -120 : -40
        captionLabel?.superview?.layoutSubtreeIfNeeded()
    }

    // MARK: - Chapter Markers

    private var chapterMarkerLayers: [CALayer] = []

    func updateChapterMarkers(chapters: [Chapter], duration: TimeInterval) {
        // Remove old markers
        for layer in chapterMarkerLayers {
            layer.removeFromSuperlayer()
        }
        chapterMarkerLayers.removeAll()

        guard duration > 0, !chapters.isEmpty,
              let overlay = playerView.contentOverlayView else { return }
        overlay.wantsLayer = true

        let trackHeight: CGFloat = 4
        let markerWidth: CGFloat = 3
        // Approximate position of the scrubber track (near bottom of player)
        let trackY: CGFloat = 12

        for chapter in chapters {
            let fraction = CGFloat(chapter.timestamp / duration)
            let marker = CALayer()
            marker.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.9).cgColor
            marker.cornerRadius = 1
            marker.frame = CGRect(
                x: overlay.bounds.width * fraction - markerWidth / 2,
                y: trackY,
                width: markerWidth,
                height: trackHeight + 4
            )
            overlay.layer?.addSublayer(marker)
            chapterMarkerLayers.append(marker)
        }
    }

    func updateCaption(_ text: String?) {
        currentCaptionText = text
        guard let overlay = playerView.contentOverlayView else { return }

        if let text, !text.isEmpty {
            let label: NSTextField
            if let existing = captionLabel {
                label = existing
            } else {
                label = NSTextField(labelWithString: "")
                label.alignment = .center
                label.maximumNumberOfLines = 3
                label.lineBreakMode = .byWordWrapping
                label.cell?.wraps = true
                label.cell?.isScrollable = false
                label.backgroundColor = .clear
                label.isBezeled = false
                label.isEditable = false
                label.translatesAutoresizingMaskIntoConstraints = false
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                label.setContentHuggingPriority(.defaultHigh, for: .vertical)
                label.wantsLayer = true
                label.shadow = {
                    let s = NSShadow()
                    s.shadowColor = NSColor.black.withAlphaComponent(1.0)
                    s.shadowBlurRadius = 2
                    s.shadowOffset = NSSize(width: 0, height: -1)
                    return s
                }()
                overlay.addSubview(label)
                let bottom = label.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: isFullScreen ? -120 : -40)
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                    bottom,
                    label.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.5),
                ])
                captionBottomConstraint = bottom
                captionLabel = label
            }
            let fs = isFullScreen
            label.preferredMaxLayoutWidth = overlay.bounds.width * 0.5
            captionBottomConstraint?.constant = fs ? -120 : -40
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fs ? 24 : 14, weight: .medium),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ])
            label.isHidden = false
        } else {
            captionLabel?.isHidden = true
        }
    }
}
