import WeftKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The standard macOS settings window (⌘,), one tab per area.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") { GeneralSettings() }
            Tab("模型", systemImage: "sparkles") { ModelSettings() }
            Tab("活动记录", systemImage: "record.circle") { TrackingSettings() }
            Tab("计时会话", systemImage: "timer") { SessionSettings() }
            Tab("分心提醒", systemImage: "hand.raised") { BlockerSettings() }
            Tab("数据", systemImage: "externaldrive") { DataSettings() }
        }
        .frame(width: 560)
        .frame(minHeight: 460)
        .onAppear { model.refreshPermissions() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Toggle("登录时启动 Weft", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in LaunchAtLogin.set(enabled) }
                Toggle("暂停记录", isOn: $prefs.trackingPaused)
            }
            Section("工作时间") {
                Picker("每日目标", selection: $prefs.workHoursTarget) {
                    ForEach([4.0, 5, 6, 7, 7.5, 8, 8.5, 9, 10, 12], id: \.self) { hours in
                        Text(Format.duration(hours * 3600)).tag(hours)
                    }
                }
                Toggle("达到目标或工作过久时提醒", isOn: $prefs.workHoursNotifications)
            }
            Section("权限") {
                PermissionRow(
                    title: "辅助功能",
                    detail: "用于读取当前窗口标题。",
                    granted: model.accessibilityGranted,
                    action: { SystemProbe.requestAccessibility(); SystemSettings.openAccessibility() }
                )
                LabeledContent {
                    Button("打开设置") { SystemSettings.openAutomation() }
                } label: {
                    Text("浏览器")
                    Text("每个浏览器首次使用时会请求读取当前标签页网址的权限。")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("授予权限", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

// MARK: - Model

private struct ModelSettings: View {
    @Environment(AppModel.self) private var model
    @State private var baseURL = ""
    @State private var modelName = ""
    @State private var apiKey = ""
    @State private var loaded = false
    /// The category the server gave Xcode, or why it couldn't answer.
    @State private var check: Result<String, any Error>?
    @State private var isChecking = false
    /// Bumped to check the server again.
    @State private var checks = 0
    @State private var saveError: String?

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Picker("分类与总结模型", selection: $prefs.modelProvider) {
                    Text("Apple Intelligence").tag(ModelProvider.appleIntelligence)
                    Text("OpenAI 兼容接口").tag(ModelProvider.openAICompatible)
                }
                LabeledContent {
                    switch (model.classifier.aiAvailability, prefs.modelProvider) {
                    case (.available, .appleIntelligence):
                        Label("已就绪", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case (.unavailable, .appleIntelligence):
                        Button("打开设置") { SystemSettings.openAppleIntelligence() }
                    case (.unavailable, .openAICompatible):
                        Label("尚未配置", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case (.available, .openAICompatible):
                        if isChecking {
                            ProgressView().controlSize(.small)
                        } else if case .success = check {
                            Label("连接成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if case .failure = check {
                            Label("连接失败", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                    }
                } label: {
                    Text("状态")
                    switch (model.classifier.aiAvailability, prefs.modelProvider) {
                    case (.available, .appleIntelligence):
                        Text("在此 Mac 上本地运行。")
                    case (.unavailable(let reason), _):
                        Text("\(reason) 模型不可用时，Weft 仍可使用规则与启发式分类。")
                    case (.available, .openAICompatible):
                        switch check {
                        case _ where isChecking: Text("正在测试 \(host)…")
                        case .success(let category)?: Text("已连接 \(host)，测试分类结果：Xcode → \(category)。")
                        case .failure(let error)?: Text("\(error.localizedDescription) 接口恢复前使用规则和启发式分类。")
                        case nil: Text("请求发送至 \(host).")
                        }
                    }
                }
            } footer: {
                Text("模型用于未知应用和网站的分类、活动描述以及每日回顾。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if prefs.modelProvider == .openAICompatible {
                Section {
                    TextField("Base URL", text: $baseURL, prompt: Text(RemoteModelConfig.defaultBaseURL))
                    TextField("模型", text: $modelName, prompt: Text("gpt-5-mini"))
                    SecureField("API Key", text: $apiKey, prompt: Text("本地服务可不填写"))
                    HStack {
                        Spacer()
                        Button("保存并连接", action: save).disabled(isChecking)
                        Button("测试已保存的配置") { checks += 1 }.disabled(isChecking || prefs.remoteModel.isEmpty)
                        Button("重试待处理活动") {
                            model.classifier.retryPending()
                            model.timeEntries.retryFailed()
                        }.disabled(isChecking || prefs.remoteModel.isEmpty)
                    }
                } header: {
                    Text("模型服务器")
                } footer: {
                    Text("支持 OpenAI、OpenRouter、DeepSeek、Ollama、LM Studio 等 Chat Completions 兼容接口。保存并启用后，未知应用和网站、窗口标题、活动片段及每日统计会发送至你配置的服务。API Key 保存在系统钥匙串中。")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: loadServer)
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好") { saveError = nil }
        } message: { Text(saveError ?? "") }
        .task(id: checks) { if checks > 0 { await checkServer() } }
        .onChange(of: prefs.modelProvider) {
            model.applyModelChoice()
            loadServer()
            check = nil
        }
    }

    private var host: String {
        RemoteModelConfig(baseURL: model.preferences.remoteBaseURL, model: "", apiKey: "").endpoint?.host() ?? "the server"
    }

    /// Fills in the saved server, reading the keychain only once a remote model is chosen.
    private func loadServer() {
        guard !loaded, model.preferences.modelProvider == .openAICompatible else { return }
        baseURL = model.preferences.remoteBaseURL
        modelName = model.preferences.remoteModel
        apiKey = Keychain.string(for: AppModel.apiKeyAccount) ?? ""
        loaded = true
    }

    /// Saves the server, switches to it and checks that it answers.
    private func save() {
        let config = RemoteModelConfig(baseURL: baseURL, model: modelName, apiKey: apiKey)
        guard config.endpoint != nil, !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            saveError = "请填写有效的 HTTP(S) 接口地址和模型名称。"
            return
        }
        do { try Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: AppModel.apiKeyAccount) }
        catch { saveError = error.localizedDescription; return }
        model.preferences.remoteBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        model.preferences.remoteModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        model.applyModelChoice()
        checks += 1
    }

    /// Asks the server about Xcode, so Status says whether it really answers rather than
    /// only whether it's filled in. Runs when the tab opens, the model changes or on Save.
    private func checkServer() async {
        check = nil
        isChecking = false
        guard model.preferences.modelProvider == .openAICompatible, model.classifier.aiAvailability == .available
        else { return }
        isChecking = true
        let outcome: Result<String, any Error>
        do {
            let xcode = ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode")
            let result = try await model.ai.classify(xcode, categories: model.classifier.categories)
            outcome = .success(model.classifier.category(result.categoryKey).name)
        } catch {
            outcome = .failure(error)
        }
        // A newer check replaced this one.
        guard !Task.isCancelled else { return }
        check = outcome
        isChecking = false
    }
}

// MARK: - Tracking

private struct TrackingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var newDomain = ""

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Picker("无操作后视为离开", selection: $prefs.idleThresholdMinutes) {
                    ForEach([1, 2, 3, 5, 10, 15, 30], id: \.self) { Text("\($0) 分钟无操作").tag($0) }
                }
            } footer: {
                Text("会议和视频通话不会因无操作而被视为离开。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("隐私") {
                Toggle("不记录窗口标题", isOn: $prefs.stripTitles)
                Toggle("网址仅记录域名", isOn: $prefs.urlHostOnly)
            }
            Section {
                ForEach(prefs.excludedBundleIDs, id: \.self) { bundleID in
                    RemovableRow {
                        AppLabel(bundleID: bundleID)
                    } onRemove: {
                        prefs.excludedBundleIDs.removeAll { $0 == bundleID }
                    }
                }
                AppPicker(excluding: Set(prefs.excludedBundleIDs)) { bundleID in
                    prefs.excludedBundleIDs.append(bundleID)
                }
            } header: {
                Text("不记录以下应用")
            }
            Section("不记录以下网站") {
                ForEach(prefs.excludedDomains, id: \.self) { domain in
                    RemovableRow {
                        Label(domain, systemImage: "globe")
                    } onRemove: {
                        prefs.excludedDomains.removeAll { $0 == domain }
                    }
                }
                HStack {
                    TextField("域名", text: $newDomain, prompt: Text("bank.example.com"))
                        .labelsHidden()
                        .onSubmit(addDomain)
                    Button("添加", action: addDomain)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addDomain() {
        var value = newDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let domain = ActivityContext.domain(from: value.contains("://") ? value : "https://\(value)") { value = domain }
        guard !value.isEmpty, !model.preferences.excludedDomains.contains(value) else { return }
        model.preferences.excludedDomains.append(value)
        newDomain = ""
    }
}

/// Adds an app from the ones currently running, or any app chosen in an open panel.
private struct AppPicker: View {
    let excluding: Set<String>
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
                .filter { !excluding.contains($0.0) && $0.0 != Bundle.main.bundleIdentifier }
                .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            Section("正在运行的应用") {
                ForEach(running, id: \.0) { bundleID, name in
                    Button {
                        onPick(bundleID)
                    } label: {
                        Label { Text(name) } icon: { Image(nsImage: AppIcons.icon(for: bundleID)) }
                    }
                }
            }
            Divider()
            Button("Choose Another App…", action: chooseApp)
        } label: {
            Label("Add App", systemImage: "plus")
        }
        .fixedSize()
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier, !excluding.contains(bundleID) else { return }
        onPick(bundleID)
    }
}

struct AppLabel: View {
    let bundleID: String

    var body: some View {
        Label {
            Text(Self.name(for: bundleID))
        } icon: {
            Image(nsImage: AppIcons.icon(for: bundleID)).resizable().frame(width: 18, height: 18)
        }
    }

    static func name(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct RemovableRow<Content: View>: View {
    @ViewBuilder let content: Content
    let onRemove: () -> Void

    var body: some View {
        HStack {
            content
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Remove")
        }
    }
}

// MARK: - Sessions

private struct SessionSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section("默认时长") {
                durationPicker("专注", $prefs.defaultFocusMinutes, options: [15, 20, 25, 30, 45, 50, 60, 90, 120])
                durationPicker("会议", $prefs.defaultMeetingMinutes, options: [15, 20, 25, 30, 45, 60, 90, 120])
                durationPicker("休息", $prefs.defaultBreakMinutes, options: [1, 3, 5, 10, 15, 20, 30])
                Toggle("全屏显示休息", isOn: $prefs.fullScreenBreak)
            }
            Section {
                Toggle("提醒我休息", isOn: $prefs.breakRemindersEnabled)
                durationPicker("连续工作时长", $prefs.breakReminderMinutes, options: [20, 30, 45, 60, 75, 90, 120])
                    .disabled(!prefs.breakRemindersEnabled)
                durationPicker("稍后提醒间隔", $prefs.snoozeMinutes, options: [5, 10, 15, 20, 30])
                    .disabled(!prefs.breakRemindersEnabled)
            } header: {
                Text("休息提醒")
            } footer: {
                Text("只计算活跃时间；离开后重置连续工作计时。")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func durationPicker(_ title: String, _ value: Binding<Int>, options: [Int]) -> some View {
        Picker(title, selection: value) {
            ForEach(Array(Set(options + [value.wrappedValue])).sorted(), id: \.self) { minutes in
                Text(Format.minutesLabel(minutes)).tag(minutes)
            }
        }
    }
}

// MARK: - Blocker

private struct BlockerSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.preferences
        Form {
            Section {
                Toggle("专注期间提醒分心", isOn: $prefs.blockerEnabled)
                Picker("提示方式", selection: $prefs.blockerStyle) {
                    Text("全屏提醒").tag(BlockerStyle.overlay)
                    Text("通知").tag(BlockerStyle.notification)
                }
                .pickerStyle(.segmented)
                .disabled(!prefs.blockerEnabled)
                Picker("停留多久后提醒", selection: $prefs.refocusThresholdSeconds) {
                    ForEach(Array(Set([0, 5, 10, 15, 30, 60, prefs.refocusThresholdSeconds])).sorted(), id: \.self) { seconds in
                        Text(seconds == 0 ? "立即" : "\(seconds) 秒").tag(seconds)
                    }
                }
                .disabled(!prefs.blockerEnabled)
            } footer: {
                Text("被标记为分心的分类会触发提醒，可在“分类”中调整。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("不提醒以下活动") {
                if prefs.blockerAllowList.isEmpty {
                    Text("标记为“不算分心”的应用和网站会显示在这里。")
                        .foregroundStyle(.secondary)
                }
                ForEach(prefs.blockerAllowList, id: \.self) { key in
                    RemovableRow {
                        AllowListLabel(key: key)
                    } onRemove: {
                        prefs.blockerAllowList.removeAll { $0 == key }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Allow-list keys are classification keys: `bundleID` or `bundleID|domain`.
private struct AllowListLabel: View {
    let key: String

    var body: some View {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            Label(parts[1], systemImage: "globe")
        } else {
            AppLabel(bundleID: parts[0])
        }
    }
}

// MARK: - Data

private struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.modelContext) private var modelContext
    @State private var exportMessage: String?

    private var dataFolder: URL { WeftSchema.dataFolder }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Button("导出 CSV…", action: exportCSV)
                } label: {
                    Text("Export all activity")
                    Text("Every tracked entry with app, title, URL and category.")
                }
                if let exportMessage {
                    Text(exportMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([dataFolder]) }
                } label: {
                    Text("Data folder")
                    Text("Everything stays on this Mac, in \(dataFolder.path(percentEncoded: false)).")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "weft-activity.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(sortBy: [SortDescriptor(\.start)]))) ?? []
        let iso = ISO8601DateFormatter()
        var csv = "start,end,duration_seconds,app,bundle_id,domain,title,url,category,classification\n"
        for segment in segments {
            let fields: [String] = [
                iso.string(from: segment.start), iso.string(from: segment.end), String(Int(segment.duration)),
                segment.appName, segment.bundleID, segment.domain ?? "", segment.title ?? "", segment.url ?? "",
                model.classifier.category(segment.categoryKey).name, segment.classificationSourceRaw,
            ]
            csv += fields.map(Self.csvEscape).joined(separator: ",") + "\n"
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "Exported \(segments.count) entries."
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private static func csvEscape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
