import AppKit

let launcherWindowSize = NSSize(width: 760, height: 500)

func configureLauncherWindow(
    _ window: NSWindow, status: NSTextField, detail: NSTextField, progress: NSProgressIndicator,
    play: NSButton, update: NSButton, logs: NSButton, info: NSButton, footerText: String
) {
    let gold = NSColor(srgbRed: 0.91, green: 0.75, blue: 0.47, alpha: 1)
    let burgundy = NSColor(srgbRed: 0.43, green: 0.14, blue: 0.19, alpha: 1)
    let content = NSView()
    content.wantsLayer = true
    content.layer?.backgroundColor = NSColor(srgbRed: 0.066, green: 0.064, blue: 0.075, alpha: 1).cgColor
    window.contentView = content

    let art = NSImageView()
    if let jpeg = Data(base64Encoded: embeddedLauncherArtwork, options: .ignoreUnknownCharacters),
       let image = NSImage(data: jpeg) {
        image.size = launcherWindowSize
        art.image = image
    }
    art.imageScaling = .scaleAxesIndependently
    art.setAccessibilityElement(false)

    let title = NSTextField(labelWithString: "NNG")
    title.font = NSFont(name: "Georgia-Bold", size: 64) ?? .systemFont(ofSize: 64, weight: .bold)
    title.textColor = gold
    let subtitle = NSTextField(labelWithString: "")
    subtitle.attributedStringValue = NSAttributedString(string: "LINEAGE II  ·  HIGH FIVE", attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        .kern: 2.2,
        .foregroundColor: NSColor(srgbRed: 0.96, green: 0.93, blue: 0.87, alpha: 1)
    ])
    let tagline = NSTextField(labelWithString: "Твой мир. Твои правила.")
    tagline.font = .systemFont(ofSize: 14, weight: .medium)
    tagline.textColor = .labelColor
    let accent = NSView()
    accent.wantsLayer = true
    accent.layer?.backgroundColor = gold.cgColor

    let panel = NSView()
    panel.wantsLayer = true
    panel.layer?.backgroundColor = NSColor(srgbRed: 0.075, green: 0.075, blue: 0.09, alpha: 0.97).cgColor
    panel.layer?.cornerRadius = 8
    panel.layer?.borderWidth = 1
    panel.layer?.borderColor = gold.withAlphaComponent(0.28).cgColor

    status.font = .systemFont(ofSize: 19, weight: .semibold)
    status.lineBreakMode = .byTruncatingTail
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    detail.font = .systemFont(ofSize: 13)
    detail.textColor = .secondaryLabelColor
    detail.maximumNumberOfLines = 3
    progress.style = .spinning
    progress.controlSize = .small
    progress.isIndeterminate = true
    progress.isDisplayedWhenStopped = false

    for button in [update, play] {
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 15, weight: .semibold)
    }
    play.bezelColor = burgundy
    play.contentTintColor = gold
    play.keyEquivalent = "\r"
    update.contentTintColor = .labelColor
    logs.bezelStyle = .inline
    info.bezelStyle = .inline
    let footer = NSTextField(labelWithString: footerText)
    footer.font = .systemFont(ofSize: 11)
    footer.textColor = .secondaryLabelColor

    for view in [art, title, subtitle, accent, tagline, panel, footer, logs, info] {
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
    }
    for view in [status, detail, progress, update, play] {
        view.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(view)
    }
    NSLayoutConstraint.activate([
        art.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        art.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        art.topAnchor.constraint(equalTo: content.topAnchor),
        art.bottomAnchor.constraint(equalTo: content.bottomAnchor),

        title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 48),
        title.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
        subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor, constant: 2),
        subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
        accent.leadingAnchor.constraint(equalTo: subtitle.leadingAnchor),
        accent.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
        accent.widthAnchor.constraint(equalToConstant: 70),
        accent.heightAnchor.constraint(equalToConstant: 2),
        tagline.leadingAnchor.constraint(equalTo: subtitle.leadingAnchor),
        tagline.topAnchor.constraint(equalTo: accent.bottomAnchor, constant: 16),

        panel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
        panel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
        panel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -46),
        panel.heightAnchor.constraint(equalToConstant: 168),
        status.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 20),
        status.topAnchor.constraint(equalTo: panel.topAnchor, constant: 17),
        progress.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 12),
        progress.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -20),
        progress.centerYAnchor.constraint(equalTo: status.centerYAnchor),
        detail.leadingAnchor.constraint(equalTo: status.leadingAnchor),
        detail.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -20),
        detail.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 7),

        update.leadingAnchor.constraint(equalTo: status.leadingAnchor),
        update.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -14),
        update.widthAnchor.constraint(equalToConstant: 230),
        update.heightAnchor.constraint(equalToConstant: 40),
        play.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
        play.bottomAnchor.constraint(equalTo: update.bottomAnchor),
        play.widthAnchor.constraint(equalTo: update.widthAnchor),
        play.heightAnchor.constraint(equalTo: update.heightAnchor),
        detail.bottomAnchor.constraint(lessThanOrEqualTo: update.topAnchor, constant: -7),

        footer.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 4),
        footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -15),
        info.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -4),
        info.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
        logs.trailingAnchor.constraint(equalTo: info.leadingAnchor, constant: -18),
        logs.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
    ])
    window.setContentSize(launcherWindowSize)
    window.center()
}
