import SwiftUI

struct ShareSettingsSheet: View {
    let recording: Recording
    @Environment(RecordingStore.self) private var store
    @Binding var isPresented: Bool
    @State private var uploadTracker = ShareUploadTracker.shared
    @State private var toast = ToastManager.shared
    @State private var sharePassword = ""
    @State private var ctaURLString = ""
    @State private var ctaText = ""
    @State private var showUnshareConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Share")
                    .font(VoomTheme.fontTitle())
                    .foregroundStyle(VoomTheme.textPrimary)
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(VoomTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, VoomTheme.spacingXL)
            .padding(.top, VoomTheme.spacingXL)
            .padding(.bottom, VoomTheme.spacingLG)

            Divider()
                .foregroundStyle(VoomTheme.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: VoomTheme.spacingXL) {
                    // Share Link Section
                    shareLinkSection

                    Divider()
                        .foregroundStyle(VoomTheme.borderSubtle)

                    // Password Protection
                    passwordSection

                    Divider()
                        .foregroundStyle(VoomTheme.borderSubtle)

                    // Call to Action
                    ctaSection

                    Divider()
                        .foregroundStyle(VoomTheme.borderSubtle)

                    // Share File
                    shareFileSection
                }
                .padding(VoomTheme.spacingXL)
            }

            Divider()
                .foregroundStyle(VoomTheme.borderSubtle)

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(VoomTheme.textSecondary)
                Button("Save Settings") {
                    saveSettings()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(VoomTheme.spacingLG)
        }
        .frame(width: 440, height: 520)
        .onAppear {
            sharePassword = recording.sharePassword ?? ""
            ctaURLString = recording.ctaURL?.absoluteString ?? ""
            ctaText = recording.ctaText ?? ""
        }
        .alert("Remove Share Link?", isPresented: $showUnshareConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task { await removeShareLink() }
            }
        } message: {
            Text("This will remove the shared link. Anyone with the link will no longer be able to view the recording.")
        }
    }

    // MARK: - Share Link

    @ViewBuilder
    private var shareLinkSection: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingMD) {
            Label("Share Link", systemImage: "link")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoomTheme.textPrimary)

            if uploadTracker.isUploading(recording.id) {
                HStack(spacing: VoomTheme.spacingSM) {
                    ProgressView(value: uploadTracker.progress(for: recording.id) ?? 0)
                    Text("Uploading...")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textSecondary)
                }
            } else if recording.isShared && !recording.isShareExpired {
                HStack(spacing: VoomTheme.spacingSM) {
                    if let url = recording.shareURL {
                        Text(url.absoluteString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(VoomTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        guard let url = recording.shareURL else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        toast.success("Link copied!")
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if let desc = recording.shareExpiryDescription {
                    Text(desc)
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.accentOrange)
                }

                Button(role: .destructive) {
                    showUnshareConfirmation = true
                } label: {
                    Label("Remove Link", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
            } else {
                Text("Upload this recording and get a shareable link.")
                    .font(VoomTheme.fontCaption())
                    .foregroundStyle(VoomTheme.textTertiary)

                Button {
                    Task { await shareViaLink() }
                } label: {
                    Label("Upload & Share", systemImage: "arrow.up.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
    }

    // MARK: - Password

    @ViewBuilder
    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
            Label("Password Protection", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoomTheme.textPrimary)

            Text("Viewers must enter this password before watching.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)

            SecureField("Optional password", text: $sharePassword)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    // MARK: - CTA

    @ViewBuilder
    private var ctaSection: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
            Label("Call to Action", systemImage: "hand.tap")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoomTheme.textPrimary)

            Text("Show a button when the video ends.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)

            TextField("URL (e.g. https://example.com)", text: $ctaURLString)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            TextField("Button text (e.g. Learn More)", text: $ctaText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
    }

    // MARK: - Share File

    @ViewBuilder
    private var shareFileSection: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
            Label("Share File", systemImage: "square.and.arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(VoomTheme.textPrimary)

            Text("Share the video file directly via AirDrop, Messages, etc.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)

            ShareLink(item: recording.fileURL) {
                Label("Share File", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .controlSize(.regular)
        }
    }

    // MARK: - Actions

    private func saveSettings() {
        var updated = recording
        updated.sharePassword = sharePassword.isEmpty ? nil : sharePassword
        updated.ctaURL = URL(string: ctaURLString)
        updated.ctaText = ctaText.isEmpty ? nil : ctaText
        store.update(updated)
        isPresented = false
        toast.success("Share settings saved")
    }

    private func shareViaLink() async {
        do {
            let result = try await ShareService.shared.share(recording: recording)
            var updated = recording
            updated.shareURL = result.shareURL
            updated.shareCode = result.shareCode
            updated.shareExpiresAt = result.expiresAt
            store.update(updated)

            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.shareURL.absoluteString, forType: .string)
            toast.success("Uploaded & link copied!", icon: "link.badge.plus")
        } catch {
            toast.error("Share failed: \(error.localizedDescription)")
        }
    }

    private func removeShareLink() async {
        guard let code = recording.shareCode else { return }
        do {
            try await ShareService.shared.deleteShare(shareCode: code)
            var updated = recording
            updated.shareURL = nil
            updated.shareCode = nil
            updated.shareExpiresAt = nil
            store.update(updated)
            toast.success("Link removed", icon: "link.badge.plus")
        } catch {
            toast.error("Unshare failed: \(error.localizedDescription)")
        }
    }
}
