
import SwiftUI

extension DashboardView {
    var permissionsSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 12) {
                    permissionIcon(
                        systemImage: "shield.lefthalf.filled",
                        foreground: ABDesign.accent,
                        background: ABDesign.accent.opacity(0.10),
                        size: 42
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("System Permissions", comment: "Permissions screen hero title")
                            .font(ABTypography.bodySemibold)
                            .foregroundStyle(ABDesign.primaryText)
                        Text("AnyBrief requests access to the required features for stable recording, transcription, and notifications.", comment: "Permissions screen hero description")
                            .font(ABTypography.caption)
                            .foregroundStyle(ABDesign.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 560, alignment: .leading)
                        permissionRecheckStatus
                    }
                    .padding(.top, 2)

                    Spacer(minLength: 12)

                    permissionRecheckButton
                }

                VStack(spacing: 0) {
                    ForEach(viewModel.permissions) { permission in
                        permissionRow(permission)

                        if permission.id != viewModel.permissions.last?.id {
                            Divider()
                        }
                    }
                }


                HStack(alignment: .center, spacing: 18) {
                    permissionIcon(
                        systemImage: "shield.checkerboard",
                        foreground: ABDesign.info,
                        background: ABDesign.info.opacity(0.12),
                        size: 38
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your privacy is our priority", comment: "Permissions privacy card title")
                            .font(ABTypography.bodySemibold)
                            .foregroundStyle(ABDesign.primaryText)
                        Text("Audio recording and transcription always happen locally. Transcript text is sent to an external LLM only if you configure and enable that connection yourself; audio and screenshots are never sent.", comment: "Permissions privacy card description")
                            .font(ABTypography.caption)
                            .foregroundStyle(ABDesign.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(ABDesign.infoBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ABDesign.info.opacity(0.12), lineWidth: 1)
                        )
                )
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    var permissionRecheckButton: some View {
        Button {
            viewModel.recheckPermissions()
        } label: {
            HStack(spacing: 8) {
                if viewModel.isRecheckingPermissions {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(viewModel.isRecheckingPermissions ? String(localized: "Checking…") : String(localized: "Recheck"))
            }
            .font(ABTypography.bodyMedium)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRecheckingPermissions)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ABDesign.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ABDesign.hairline, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    var permissionRecheckStatus: some View {
        if viewModel.isRecheckingPermissions {
            Label(String(localized: "Checking permissions…"), systemImage: "arrow.triangle.2.circlepath")
                .font(ABTypography.captionMedium)
                .foregroundStyle(ABDesign.secondaryText)
        } else if let date = viewModel.lastPermissionsRecheckAt {
            Label(
                String(
                    format: String(localized: "Checked at %@"),
                    Self.permissionRecheckTimeFormatter.string(from: date)
                ),
                systemImage: "checkmark.circle"
            )
            .font(ABTypography.captionMedium)
            .foregroundStyle(ABDesign.green)
        }
    }

    func permissionRow(_ permission: DashboardViewModel.PermissionRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            permissionIcon(
                systemImage: permissionIconName(for: permission.id),
                foreground: ABDesign.accent,
                background: ABDesign.accent.opacity(0.10),
                size: 34
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title)
                    .font(ABTypography.bodySemibold)
                    .foregroundStyle(ABDesign.primaryText)
                Text(permission.detail)
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

            }

            Spacer(minLength: 12)

            permissionStatusPill(permission)

            permissionActionButton(permission)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ABDesign.cardBackground)
    }

    func permissionIcon(
        systemImage: String,
        foreground: Color,
        background: Color,
        size: CGFloat
    ) -> some View {
        Image(systemName: systemImage)
            .font(ABTypography.icon(inContainer: size))
            .foregroundStyle(foreground)
            .frame(width: size, height: size)
            .background(Circle().fill(background))
    }

    func permissionStatusPill(_ permission: DashboardViewModel.PermissionRow) -> some View {
        let granted = permission.rawStatus == .granted
        return Label {
            Text(permission.status)
        } icon: {
            Image(systemName: granted ? "checkmark.circle" : "exclamationmark.circle")
        }
        .foregroundStyle(granted ? ABDesign.green : ABDesign.yellow)
        .font(ABTypography.captionSemibold)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            Capsule()
                .fill((granted ? ABDesign.green : ABDesign.yellow).opacity(0.10))
        )
    }

    func permissionActionButton(_ permission: DashboardViewModel.PermissionRow) -> some View {
        Button {
            if permission.id == "microphone" && permission.rawStatus == .notDetermined {
                viewModel.requestMicrophone()
            } else if permission.id == "notifications" && permission.rawStatus == .notDetermined {
                viewModel.requestNotifications()
            } else if permission.id == "screenRecording" && permission.rawStatus != .granted {
                viewModel.requestScreenRecording()
            } else {
                viewModel.openSystemSettings(for: permission)
            }
        } label: {
            HStack(spacing: 8) {
                if viewModel.requestingPermissionIDs.contains(permission.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "gearshape")
                }
                Text(permissionActionTitle(for: permission))
            }
                .font(ABTypography.bodyMedium)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(width: 170, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.requestingPermissionIDs.contains(permission.id))
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ABDesign.controlBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(ABDesign.hairline, lineWidth: 1)
                )
        )
    }

    func permissionActionTitle(for permission: DashboardViewModel.PermissionRow) -> String {
        if permission.id == "microphone" && permission.rawStatus == .notDetermined {
            return String(localized: "Request Access")
        }
        if permission.id == "notifications" && permission.rawStatus == .notDetermined {
            return String(localized: "Request Access")
        }
        if permission.id == "screenRecording" && permission.rawStatus != .granted {
            return String(localized: "Request Access")
        }
        return String(localized: "Open System Settings")
    }

    func permissionIconName(for id: String) -> String {
        switch id {
        case "microphone":
            return "mic"
        case "screenRecording":
            return "display"
        case "notifications":
            return "bell"
        default:
            return "shield"
        }
    }

    private static let permissionRecheckTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
