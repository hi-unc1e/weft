import WeftKit
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "circle.circle").font(.system(size: 40)).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("欢迎使用 Weft").font(.title.bold())
                    Text("自动记录时间，数据保存在你的 Mac。使用远程模型时，相关活动信息会发送至你配置的服务。").foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                bullet("record.circle", "记录前台应用、窗口标题和浏览器网址，不采集截图和键盘内容。")
                bullet("sparkles", "未知应用和网站交给所选模型分类。Apple 模型在本机运行；远程接口会接收相关活动信息，可在设置中选择。")
                bullet("scope", "从菜单栏开始专注、会议或休息计时。")
            }

            Form {
                PermissionRow(
                    title: "辅助功能",
                    detail: "用于读取窗口标题。",
                    granted: model.accessibilityGranted,
                    action: { SystemProbe.requestAccessibility(); SystemSettings.openAccessibility() }
                )
                LabeledContent {
                    switch model.classifier.aiAvailability {
                    case .available: Label("可用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .unavailable:
                        // Where Apple Intelligence isn't offered, another model is the way forward.
                        HStack {
                            Button("打开设置") { SystemSettings.openAppleIntelligence() }
                            SettingsLink { Text("配置其他模型…") }
                        }
                    }
                } label: {
                    Text("Apple Intelligence")
                    switch model.classifier.aiAvailability {
                    case .available: Text("本地模型已就绪。")
                    case .unavailable(let reason): Text("\(reason) 也可手动分类或配置 OpenAI 兼容接口。")
                    }
                }
                LabeledContent("浏览器") {
                    Text("每个浏览器首次使用时会请求自动化权限。").foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 210)

            HStack {
                Spacer()
                Button("开始使用") {
                    model.preferences.hasCompletedOnboarding = true
                    onDone()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .task {
            // Pick up the Accessibility grant without requiring a relaunch.
            while !Task.isCancelled && !model.accessibilityGranted {
                try? await Task.sleep(for: .seconds(1))
                model.refreshPermissions()
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
        }
    }
}
