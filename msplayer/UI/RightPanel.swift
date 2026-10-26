import Foundation
import SwiftUI

struct RightPanel: View {

    let onSelect: (MenuSheet) -> Void
    let onExit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "play.tv")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.cyan)
                Text("菜单")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)

            item(.lines, icon: "list.number", title: "线路选择")
            item(.subscriptions, icon: "link", title: "列表订阅")
            item(.epg, icon: "calendar", title: "EPG订阅")
            item(.display, icon: "aspectratio", title: "显示设置")
            item(.decoder, icon: "cpu", title: "解码更换")
            item(.tracks, icon: "captions.bubble", title: "音轨字幕")
            item(.app, icon: "gearshape", title: "应用设置")
            item(.about, icon: "info.circle", title: "关于应用")

            Button(action: onExit) {
                row(icon: "power", title: "退出应用", tint: .red.opacity(0.9))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.07).opacity(0.94))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }

    private func item(_ sheet: MenuSheet, icon: String, title: String) -> some View {
        Button {
            onSelect(sheet)
        } label: {
            row(icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }

    private func row(icon: String, title: String, tint: Color = .white) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 20)
                .foregroundColor(tint.opacity(0.9))
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(tint.opacity(0.92))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.18))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.001))
        )
    }
}
