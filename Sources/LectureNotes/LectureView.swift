import SwiftUI

/// One past lecture: rename it, read its notes or transcript, and act on it.
struct LectureDetail: View {
    @EnvironmentObject var state: AppState
    let record: LectureRecord

    enum Content: Hashable { case notes, transcript }

    @State private var name = ""
    @State private var content: Content = .notes
    @State private var notes: String?
    @State private var transcript: String?
    @State private var hasSlides = false
    @FocusState private var editingName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { close() } label: {
                    Label("History", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                }
                Spacer()
                moreMenu
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            Card {
                VStack(alignment: .leading, spacing: 3) {
                    TextField("Lecture name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                        .focused($editingName)
                        .onSubmit(commitName)
                        .help("Click to rename")
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                if let important = record.meta.important, !important.isEmpty {
                    CardDivider()
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(important, id: \.self) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "flag.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                Text(item).font(.system(size: 12.5))
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.orange.opacity(0.07))
                }

                if state.isProcessing(record) {
                    CardDivider()
                    Row(icon: "hourglass", tint: Brand.indigo, title: state.statusLabel) {
                        ProgressView().controlSize(.small)
                    }
                }

                CardDivider()
                Picker("", selection: $content) {
                    Text("Notes").tag(Content.notes)
                    Text("Transcript").tag(Content.transcript)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                CardDivider()

                ScrollView {
                    Group {
                        switch content {
                        case .notes:
                            if let notes { NotesText(markdown: notes) } else { empty("No notes yet", icon: "doc.text") }
                        case .transcript:
                            if let transcript {
                                Text(transcript).font(.system(size: 13)).lineSpacing(3)
                            } else {
                                empty("No transcript saved", icon: "text.quote")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(14)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: 320)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: DS.cardRadius, bottomTrailingRadius: DS.cardRadius))
            }

            actions
        }
        .onAppear {
            name = record.name
            if state.renameRequested {
                state.renameRequested = false
                editingName = true
            }
        }
        .onChange(of: record.name) { _, new in if !editingName { name = new } }
        .onChange(of: editingName) { _, editing in if !editing { commitName() } }
        .onDisappear(perform: commitName)
        .task(id: "\(record.dir.path)|\(state.phase)|\(record.hasNotes)") { load() }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 8) {
            if notes != nil {
                CopyNotesButton { state.copyNotes(record.dir) }
                if let docURL = record.docURL {
                    SmallActionButton(title: "Google Doc", icon: "arrow.up.right") { NSWorkspace.shared.open(docURL) }
                } else {
                    SmallActionButton(title: "Full page", icon: "arrow.up.right") { state.openNotes(record.dir) }
                }
            } else if !state.isProcessing(record) {
                SmallActionButton(title: "Make notes", icon: "sparkles", prominent: true) {
                    state.regenerate(record, retranscribe: false)
                }
            }
        }
        .disabled(state.phase.isBusy && notes == nil)
    }

    private var moreMenu: some View {
        Menu {
            Button(record.hasNotes ? "Make notes again" : "Make notes") { state.regenerate(record, retranscribe: false) }
            Button("Re-transcribe") { state.regenerate(record, retranscribe: true) }
            Button(hasSlides ? "Replace slides & re-transcribe…" : "Add slides & re-transcribe…") { state.addSlidesAndRetranscribe(record) }
            Divider()
            Button("Show in Finder") { state.showFiles(record.dir) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(state.isRecording || state.phase.isBusy)
        .help("More")
    }

    private var subtitle: String {
        var parts = [record.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())]
        if let duration = record.meta.duration { parts.append(AppState.format(duration)) }
        if hasSlides { parts.append("Slides") }
        if record.meta.transcriber == "whisper" { parts.append("High accuracy") }
        return parts.joined(separator: "  ·  ")
    }

    private func empty(_ text: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    private func load() {
        func read(_ file: String) -> String? {
            let text = try? String(contentsOf: record.dir.appending(path: file), encoding: .utf8)
            return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
        }
        notes = read("notes.md")
        transcript = read("transcript.txt")
        hasSlides = read("slides.txt") != nil
    }

    private func commitName() {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = record.name
        } else {
            state.rename(record, to: name)
        }
    }

    private func close() {
        editingName = false
        commitName()
        state.openLecture = nil
    }
}

/// Native rendering of the notes Markdown: headings, nested bullets, numbered lists, code, and inline styling.
struct NotesText: View {
    let markdown: String

    private enum Block {
        case heading(Int, String), bullet(Int, String, String), paragraph(String), code(String), rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(1, let text):
            inline(text).font(.system(size: 17, weight: .bold)).padding(.bottom, 2)
        case .heading(2, let text):
            inline(text).font(.system(size: 14.5, weight: .semibold)).padding(.top, 8)
        case .heading(_, let text):
            inline(text).font(.system(size: 13.5, weight: .semibold)).padding(.top, 4)
        case .bullet(let level, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).foregroundStyle(.secondary)
                inline(text)
            }
            .font(.system(size: 13))
            .padding(.leading, CGFloat(level) * 14)
        case .paragraph(let text):
            inline(text).font(.system(size: 13)).lineSpacing(2)
        case .code(let text):
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    private var blocks: [Block] {
        var blocks: [Block] = []
        var code: [String]?
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { continue }

            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if line == "---" || line == "***" {
                blocks.append(.rule)
            } else if let hashes = line.firstRange(of: #/^#{1,6} /#) {
                blocks.append(.heading(line[hashes].count - 1, String(line[hashes.upperBound...]).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                blocks.append(.bullet(indent, indent == 0 ? "•" : "◦", String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else if let number = line.firstMatch(of: #/^(\d+)[.)] /#) {
                blocks.append(.bullet(indent, "\(number.1).", String(line[number.range.upperBound...]).trimmingCharacters(in: .whitespaces)))
            } else {
                blocks.append(.paragraph(line))
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        return blocks
    }
}
