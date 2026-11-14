import Foundation
import SwiftData
import SwiftUI
import WeftKit

struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @Query(sort: \ActivitySegment.start) private var segments: [ActivitySegment]
    @State private var days = 7
    @State private var selected: String?
    @State private var search = ""
    @State private var openedAt = Date.now
    @State private var computed: ComputedReport?

    private struct ComputedReport {
        let input: ProjectReportInput
        let days: Int
        let report: ProjectReport
    }

    init() {
        let since = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now
        _segments = Query(filter: #Predicate<ActivitySegment> { $0.end > since }, sort: \.start)
    }

    var body: some View {
        @Bindable var store = model.projects
        // A stable endpoint prevents publishing a report from starting the same task again.
        // Tracking updates the segment end; refresh updates updatedAt.
        let now = max(store.updatedAt ?? openedAt, segments.last?.end ?? openedAt)
        let today = Calendar.current.startOfDay(for: now)
        let start = store.since ?? (Calendar.current.date(byAdding: .day, value: 1 - days, to: today) ?? today)
        let interval = DateInterval(start: start, end: now)
        let input: ProjectReportInput? = store.matchesSelection && store.selectedDays == days ? ProjectReportInput(activities: segments.map {
            ProjectActivity(start: $0.start, end: $0.end, title: $0.title, url: $0.url)
        }, requests: store.requests, interval: interval, projectPaths: store.projectPaths,
           sessionStats: store.sessionStats, requestsWithoutSession: store.requestsWithoutSession,
           localSessions: store.localSessions) : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("时间", selection: $days) {
                        Text("今天").tag(1)
                        Text("最近 7 天").tag(7)
                    }.pickerStyle(.segmented).frame(width: 220)
                    Spacer()
                    Toggle("读取本地 Magpie", isOn: $store.enabled).toggleStyle(.switch)
                        .onChange(of: store.enabled) { _, enabled in
                            if enabled { Task { await store.refresh(days: days) } }
                        }
                    Button { Task { await store.refresh(days: days) } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }.disabled(store.isRefreshing || !store.enabled)
                    if store.isRefreshing { ProgressView().controlSize(.small) }
                }
                Text("结合 Magpie、Codex / Claude 会话与本机 Tokei 缓存识别项目。前台时长需有明确项目或会话主题；AI 请求次数包括后台代理，不代表你投入的时间。")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("搜索项目名称、路径或会话主题", text: $search)
                    .textFieldStyle(.roundedBorder)
                if model.preferences.stripTitles {
                    Text("窗口标题记录已关闭，项目时长无法完整识别。可在设置 → 活动记录中开启。")
                        .foregroundStyle(.orange)
                } else if !model.accessibilityGranted {
                    HStack {
                        Text("当前签名身份尚无有效的辅助功能授权，无法读取窗口标题。切换到固定身份后需重新授权一次。")
                        Button("打开辅助功能设置") { SystemSettings.openAccessibility() }
                    }.foregroundStyle(.orange)
                }
                let titled = segments.filter { !($0.title ?? "").isEmpty }.count
                Text("历史窗口标题覆盖：\(titled) / \(segments.count) 条。缺失记录不能追溯补回；已识别时长仅为下限。")
                    .font(.caption).foregroundStyle(.secondary)
                if let error = store.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if input != nil, let updated = store.updatedAt {
                    Text("更新于 \(updated.formatted(date: .omitted, time: .shortened)) · 完整区间汇总 + 本地会话去重；按响应 ID 补回 \(store.recoveredRequests) 次请求。详情采样 \(store.requests.count) 条。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !store.recoveryComplete {
                        Text("部分本地请求记录未能完整对账，当前项目请求数仅为已确认的下限。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let computed, let input, computed.days == days {
                    if computed.input != input {
                        Text("正在更新项目归属，暂时显示本区间上次结果…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    projectList(computed, store: store)
                } else if !store.enabled {
                    ContentUnavailableView("项目识别已暂停", systemImage: "folder")
                } else if store.isRefreshing || input != nil || store.selectedDays != days {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("正在读取\(days == 1 ? "今天" : "最近 7 天")的项目与会话…")
                            .foregroundStyle(.secondary)
                    }.padding(.vertical)
                }
                Text("项目匹配在本机完成，不调用模型、不发送会话正文。Code 等原有分类可继续使用。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }
        .navigationTitle("最近在忙什么项目")
        .task(id: days) { await store.refresh(days: days) }
        .task(id: input) {
            guard let input else { return }
            let requestedDays = days
            do {
                let report = try await input.buildInBackground()
                try Task.checkCancellation()
                computed = ComputedReport(input: input, days: requestedDays, report: report)
            } catch is CancellationError {
                // A newer input owns the next result.
            } catch { /* Background construction only throws on cancellation. */ }
        }
    }

    @ViewBuilder private func projectList(_ computed: ComputedReport, store: ProjectStore) -> some View {
        let report = computed.report
        let start = computed.input.interval.start
        let now = computed.input.interval.end
        Group {
                if report.projects.isEmpty {
                    ContentUnavailableView(store.enabled ? "尚无可识别项目" : "项目识别已暂停", systemImage: "folder",
                        description: Text("Magpie 请求需要带会话 ID，并能在本地 Codex 或 Claude 会话中找到工作目录。"))
                }
                ForEach(report.projects.filter { usage in
                    search.isEmpty || ([usage.project.name] + usage.project.paths + usage.project.sessionTitles)
                        .contains { $0.localizedCaseInsensitiveContains(search) }
                }) { usage in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(usage.project.name, systemImage: "folder").font(.headline)
                            Spacer()
                            Text(usage.measuredActiveTime.map { "已识别前台 ≥\(Format.duration($0))" } ?? "前台时长未知").monospacedDigit()
                        }
                        HStack {
                            Text("网关已关联 \(usage.requests) 次请求 · \(usage.sessions) 个会话（含子会话）")
                            Spacer()
                            if let last = usage.lastRequest {
                                Text("最近采样 \(last.formatted(date: .abbreviated, time: .shortened))")
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        Text("本地 \(usage.localSessions) 个 · 网关已关联 \(usage.gatewaySessions) 个；跨来源按会话 ID 去重。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(selected == usage.id ? "收起活动" : "查看活动") {
                            selected = selected == usage.id ? nil : usage.id
                        }.buttonStyle(.link)
                        if selected == usage.id {
                            Text(usage.project.paths.joined(separator: "\n"))
                                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            let projectRequests = computed.input.requests.filter {
                                $0.date >= start && $0.date < now &&
                                $0.projectPath.map { usage.project.paths.contains($0) } == true
                            }
                            let titles = Array(Set(projectRequests.compactMap(\.sessionTitle) + usage.project.sessionTitles)).sorted()
                            if !titles.isEmpty {
                                Text("会话主题").font(.subheadline.weight(.medium))
                                ForEach(titles, id: \.self) { title in
                                    Label(title, systemImage: "text.bubble")
                                        .font(.callout).textSelection(.enabled)
                                }
                            }
                            let matchedActivities = Set(zip(computed.input.activities, report.activityProjectIDs).compactMap {
                                $0.1 == usage.id ? $0.0 : nil
                            })
                            let matching = segments.filter { segment in
                                matchedActivities.contains(ProjectActivity(start: segment.start, end: segment.end,
                                                                            title: segment.title, url: segment.url))
                            }
                            if matching.isEmpty {
                                Text("有 AI 请求记录，尚无明确归属的前台活动。")
                                    .font(.callout).foregroundStyle(.secondary)
                            } else { ActivityList(segments: matching) }
                        }
                    }.padding(16)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                }
                Text("待归属前台时间：\(Format.duration(report.unattributedTime)) · 无法关联项目的请求：\(report.unresolvedRequests)")
                    .font(.callout).foregroundStyle(.secondary)
        }
    }
}
