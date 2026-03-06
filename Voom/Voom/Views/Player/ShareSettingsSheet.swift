import SwiftUI
import VoomCore

struct ShareSettingsSheet: View {
    let recording: Recording
    @Environment(RecordingStore.self) private var store
    @Binding var isPresented: Bool
    @State private var uploadTracker = ShareUploadTracker.shared
    @State private var pipelineProgress = SharePipelineProgress.shared
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

            Rectangle()
                .fill(VoomTheme.borderSubtle)
                .frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: VoomTheme.spacingXL) {
                    shareLinkSection
                    Rectangle().fill(VoomTheme.borderSubtle).frame(height: 0.5)
                    passwordSection
                    Rectangle().fill(VoomTheme.borderSubtle).frame(height: 0.5)
                    ctaSection
                    Rectangle().fill(VoomTheme.borderSubtle).frame(height: 0.5)
                    shareFileSection
                }
                .padding(VoomTheme.spacingXL)
            }

            Rectangle()
                .fill(VoomTheme.borderSubtle)
                .frame(height: 0.5)

            // Footer
            HStack {
                Spacer()
                voomSecondaryButton("Cancel") { isPresented = false }
                voomPrimaryButton("Save Settings", icon: "checkmark") { saveSettings() }
            }
            .padding(VoomTheme.spacingLG)
        }
        .frame(width: 440, height: 520)
        .background(VoomTheme.backgroundPrimary)
        .preferredColorScheme(.dark)
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
                .font(VoomTheme.fontHeadline())
                .foregroundStyle(VoomTheme.textPrimary)

            if pipelineProgress.isOptimizing(recording.id) {
                HStack(spacing: VoomTheme.spacingSM) {
                    ProgressView(value: pipelineProgress.progress(for: recording.id) ?? 0)
                        .tint(VoomTheme.accentOrange)
                    Text("Optimizing...")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textSecondary)
                }
            } else if uploadTracker.isUploading(recording.id) {
                HStack(spacing: VoomTheme.spacingSM) {
                    ProgressView(value: uploadTracker.progress(for: recording.id) ?? 0)
                        .tint(VoomTheme.accentGreen)
                    Text("Uploading...")
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.textSecondary)
                }
            } else if recording.isShared && !recording.isShareExpired {
                HStack(spacing: VoomTheme.spacingSM) {
                    if let url = recording.shareURL {
                        Text(url.absoluteString)
                            .font(VoomTheme.fontMono())
                            .foregroundStyle(VoomTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    voomPrimaryButton("Copy", icon: "doc.on.doc") {
                        guard let url = recording.shareURL else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        toast.success("Link copied!")
                    }
                }

                if let desc = recording.shareExpiryDescription {
                    Text(desc)
                        .font(VoomTheme.fontCaption())
                        .foregroundStyle(VoomTheme.accentOrange)
                }

                voomDestructiveButton("Remove Link", icon: "trash") {
                    showUnshareConfirmation = true
                }
            } else {
                Text("Upload this recording and get a shareable link.")
                    .font(VoomTheme.fontCaption())
                    .foregroundStyle(VoomTheme.textTertiary)

                voomPrimaryButton("Upload & Share", icon: "arrow.up.circle.fill") {
                    Task { await shareViaLink() }
                }
                .disabled(pipelineProgress.isOptimizing(recording.id) || uploadTracker.isUploading(recording.id))
            }
        }
    }

    // MARK: - Password

    @ViewBuilder
    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
            Label("Password Protection", systemImage: "lock.shield")
                .font(VoomTheme.fontHeadline())
                .foregroundStyle(VoomTheme.textPrimary)

            Text("Viewers must enter this password before watching.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)

            voomTextField("Optional password", text: $sharePassword, isSecure: true)
        }
    }

    // MARK: - CTA

    @ViewBuilder
    private var ctaSection: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
            Label("Call to Action", systemImage: "hand.tap")
                .font(VoomTheme.fontHeadline())
                .foregroundStyle(VoomTheme.textPrimary)

            Text("Show a button when the video ends.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)

            voomTextField("URL (e.g. https://example.com)", text: $ctaURLString)
            voomTextField("Button text (e.g. Learn More)", text: $ctaText)
        }
    }

    // MARK: - Share File

    @ViewBuilder
    private var shareFileSection: some View {
        VStack(alignment: .leading, spacing: VoomTheme.spacingSM) {
            Label("Share File", systemImage: "square.and.arrow.up")
                .font(VoomTheme.fontHeadline())
                .foregroundStyle(VoomTheme.textPrimary)

            Text("Share the video file directly via AirDrop, Messages, etc.")
                .font(VoomTheme.fontCaption())
                .foregroundStyle(VoomTheme.textTertiary)

            ShareLink(item: recording.fileURL) {
                HStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .medium))
                    Text("Share File")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(VoomTheme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                        .fill(VoomTheme.backgroundCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                        .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Themed Controls

    private func voomTextField(_ placeholder: String, text: Binding<String>, isSecure: Bool = false) -> some View {
        Group {
            if isSecure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .textFieldStyle(.plain)
        .font(VoomTheme.fontBody())
        .foregroundStyle(VoomTheme.textPrimary)
        .padding(.horizontal, VoomTheme.spacingMD)
        .padding(.vertical, VoomTheme.spacingSM)
        .background(
            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                .fill(VoomTheme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                .strokeBorder(VoomTheme.borderMedium, lineWidth: 0.5)
        )
    }

    private func voomPrimaryButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                    .fill(VoomTheme.accentRed)
            )
        }
        .buttonStyle(.plain)
    }

    private func voomSecondaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(VoomTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                        .fill(VoomTheme.backgroundCard)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                        .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private func voomDestructiveButton(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(VoomTheme.accentRed)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                    .fill(VoomTheme.accentRed.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: VoomTheme.radiusMedium, style: .continuous)
                    .strokeBorder(VoomTheme.accentRed.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
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
