import SwiftUI

/// "My words": the personal vocabulary used as dictation hints and spelling fixes.
/// Editable list + refresh from Gmail/Slack + on-device import from local AI history.
@MainActor
final class VocabularyModel: ObservableObject {
    @Published var list: VocabList?
    /// Gallery renders: show the given list without calling the server.
    var preview = false
    @Published var query = ""
    @Published var newWord = ""
    @Published var busy: String?
    @Published var error: String?
    @Published var importStage: ImportStage = .idle
    enum ImportStage: Equatable { case idle, consent, scanning, preview, uploading, done(Int) }
    var scan: LocalHistoryImporter.Result?
    @Published var keep: Set<String> = []
    let api: APIClient

    init(api: APIClient) { self.api = api }

    var visible: [VocabEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return (list?.terms ?? []).filter { q.isEmpty || $0.term.lowercased().contains(q) }
    }

    func load() { Task { do { list = try await api.vocab() } catch { self.error = "\(error)" } } }

    func toggle(_ e: VocabEntry) {
        Task {
            try? await api.editVocab(enable: e.enabled ? [] : [e.term], disable: e.enabled ? [e.term] : [])
            load()
        }
    }
    func remove(_ e: VocabEntry) { Task { try? await api.editVocab(remove: [e.term]); load() } }
    func add() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        newWord = ""
        Task { try? await api.editVocab(add: [w]); load() }
    }

    func refreshFromAccounts() {
        busy = L("vocab.refreshing")
        Task {
            defer { busy = nil }
            do { _ = try await api.refreshVoice(); load() } catch { self.error = "\(error)" }
        }
    }

    // On-device import: consent → scan locally → preview (deselect) → upload terms only.
    func startImport() { importStage = .consent }
    func scanLocally() {
        importStage = .scanning
        Task.detached(priority: .userInitiated) {
            let result = LocalHistoryImporter().run()
            await MainActor.run {
                self.scan = result
                self.keep = Set((result.latin + result.hangul).map(\.term))
                self.importStage = .preview
            }
        }
    }
    func upload() {
        guard let scan else { return }
        importStage = .uploading
        Task {
            do {
                let r = try await api.importLocalVocabulary(scan, keep: keep)
                importStage = .done(r.stats.terms)
                load()
            } catch { self.error = "\(error)"; importStage = .preview }
        }
    }
}

struct VocabularyView: View {
    @ObservedObject var model: VocabularyModel
    /// Inside Settings the pane supplies insets and size; standalone it is its own window.
    var embedded = false
    var isGuest = false
    var isSignedOut = false
    var onOpenAccount: (() -> Void)? = nil
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if embedded {
            content
        } else {
            content.padding(28).frame(minWidth: 640, minHeight: 560).background(Theme.ground(scheme))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            StepHeader(L("vocab.title"), L("vocab.body"))
            if isSignedOut {
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(verbatim: L("settings.proFeature.wordsTitle")).font(Theme.display(16))
                        Text(verbatim: L("settings.proFeature.wordsBody"))
                            .font(Theme.text(13)).foregroundStyle(Theme.muted(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                        if let onOpenAccount {
                            Button(L("settings.proFeature.openAccount"), action: onOpenAccount).buttonStyle(GhostButton())
                        }
                    }
                }
                .frame(maxWidth: 520)
                Spacer(minLength: 0)
            } else {
            if let s = model.list?.stats {
                Text(verbatim: L("vocab.stats", "\(s.total)", "\(s.hints)", "\(s.replacements)").uppercased())
                    .font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
            }
            if !isGuest {
            HStack(spacing: 10) {
                Button(model.busy ?? L("vocab.refresh")) { model.refreshFromAccounts() }.buttonStyle(GhostButton()).disabled(model.busy != nil)
                Button(L("vocab.import")) { model.startImport() }.buttonStyle(GhostButton())
                Spacer()
            }
            }
            HStack(spacing: 8) {
                TextField(L("vocab.search"), text: $model.query).textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 200)
                Spacer(minLength: 12)
                TextField(L("vocab.add.placeholder"), text: $model.newWord, onCommit: model.add).textFieldStyle(.roundedBorder).frame(minWidth: 100, maxWidth: 200)
                Button(L("vocab.add")) { model.add() }.buttonStyle(PrimaryButton())
            }
            ScrollView {
                if model.visible.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: model.query.trimmingCharacters(in: .whitespaces).isEmpty ? "character.book.closed" : "magnifyingglass")
                            .font(.system(size: 20)).foregroundStyle(Theme.muted(scheme))
                        Text(verbatim: model.query.trimmingCharacters(in: .whitespaces).isEmpty
                             ? (UILanguage.isKorean ? "아직 등록된 단어가 없어요" : "No words yet")
                             : (UILanguage.isKorean ? "검색 결과가 없어요" : "No matching words"))
                            .font(Theme.text(13.5, medium: true))
                        Text(verbatim: model.query.trimmingCharacters(in: .whitespaces).isEmpty
                             ? (UILanguage.isKorean ? "위에서 단어를 직접 추가하거나 Gmail·Slack에서 가져올 수 있어요." : "Add a word above or refresh from Gmail & Slack.")
                             : (UILanguage.isKorean ? "다른 검색어로 찾아보세요." : "Try a different search term."))
                            .font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                    }
                    .frame(maxWidth: .infinity, minHeight: 160).padding(20)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visible) { e in
                            HStack(spacing: 10) {
                                Toggle("", isOn: Binding(get: { e.enabled }, set: { _ in model.toggle(e) })).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                                    .accessibilityLabel(e.term)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: e.term).font(Theme.text(13.5, medium: true)).foregroundStyle(e.enabled ? Theme.text(scheme) : Theme.muted(scheme))
                                        .lineLimit(1).truncationMode(.tail)
                                    if !e.variants.isEmpty {
                                        Text(verbatim: "← " + e.variants.prefix(3).joined(separator: ", ")).font(Theme.text(11.5)).foregroundStyle(Theme.muted(scheme)).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 8)
                                if e.hint {
                                    Text(verbatim: "HINT").font(Theme.label(9.5)).padding(.horizontal, 6).padding(.vertical, 2)
                                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.structure(scheme), lineWidth: 1))
                                }
                                Text(verbatim: e.manual ? L("vocab.manual").uppercased() : "\(e.count)").font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme)).frame(width: 44, alignment: .trailing)
                                Button { model.remove(e) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(UILanguage.isKorean ? "\(e.term) 삭제" : "Remove \(e.term)")
                                    .help(UILanguage.isKorean ? "단어 삭제" : "Remove word")
                            }
                            .padding(.vertical, 7).padding(.horizontal, 12)
                            Rectangle().fill(Theme.rule(scheme)).frame(height: 1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel(scheme)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.rule(scheme)))
            if let error = model.error { Text(verbatim: error).font(Theme.text(12)).foregroundStyle(.red) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(Theme.text(scheme))
        .onAppear { if !model.preview && !isSignedOut { model.load() } }
        .sheet(isPresented: Binding(get: { model.importStage != .idle }, set: { if !$0 { model.importStage = .idle } })) {
            ImportSheet(model: model)
        }
    }
}

/// Consent → scan → preview → upload, with the privacy promise stated before anything is read.
struct ImportSheet: View {
    @ObservedObject var model: VocabularyModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: L("vocab.import.title")).font(Theme.display(22))
            switch model.importStage {
            case .consent:
                Text(verbatim: L("vocab.import.consent")).font(Theme.text(14)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                Label { Text(verbatim: L("vocab.import.privacy")).font(Theme.text(13, medium: true)) } icon: { Image(systemName: "lock.fill") }
                Text(verbatim: L("vocab.import.found", LocalHistoryImporter().availableSources().joined(separator: ", ").ifEmpty(L("vocab.import.none"))))
                    .font(Theme.label(10.5)).foregroundStyle(Theme.muted(scheme))
                HStack { Spacer(); Button(L("vocab.cancel")) { model.importStage = .idle }.buttonStyle(GhostButton())
                    Button(L("vocab.import.scan")) { model.scanLocally() }.buttonStyle(PrimaryButton()).disabled(LocalHistoryImporter().availableSources().isEmpty) }
            case .scanning, .uploading:
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(verbatim: L(model.importStage == .scanning ? "vocab.import.scanning" : "vocab.import.uploading")).font(Theme.text(14)) }
            case .preview:
                let all = ((model.scan?.latin ?? []) + (model.scan?.hangul ?? [])).sorted { $0.score > $1.score }
                Text(verbatim: L("vocab.import.preview", "\(all.count)", "\(model.scan?.messages ?? 0)")).font(Theme.text(14))
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                        ForEach(all.prefix(300), id: \.term) { c in
                            let on = model.keep.contains(c.term)
                            Button { if on { model.keep.remove(c.term) } else { model.keep.insert(c.term) } } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 12))
                                    Text(verbatim: c.term).font(Theme.text(12.5)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(verbatim: "\(c.count)").font(Theme.label(9.5)).foregroundStyle(Theme.muted(scheme))
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 260)
                Text(verbatim: L("vocab.import.only")).font(Theme.text(12)).foregroundStyle(Theme.muted(scheme))
                HStack { Spacer(); Button(L("vocab.cancel")) { model.importStage = .idle }.buttonStyle(GhostButton())
                    Button(L("vocab.import.upload", "\(model.keep.count)")) { model.upload() }.buttonStyle(PrimaryButton()).disabled(model.keep.isEmpty) }
            case .done(let n):
                Label { Text(verbatim: L("vocab.import.done", "\(n)")).font(Theme.text(14, medium: true)) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.approval) }
                HStack { Spacer(); Button(L("ob.continue")) { model.importStage = .idle }.buttonStyle(PrimaryButton()) }
            case .idle: EmptyView()
            }
        }
        .padding(26).frame(width: 560)
        .background(Theme.ground(scheme)).foregroundStyle(Theme.text(scheme))
    }
}

extension String { func ifEmpty(_ s: String) -> String { isEmpty ? s : self } }
