import SwiftUI
import PhotosUI
import AVFoundation
import QuickLook

/// The whole app is one Messages-style conversation. Tapping Otto's name opens details.
struct ChatView: View {
    @Environment(OttoStore.self) private var store
    @State private var showDetails = false
    @State private var showCall = false
    @State private var webCall = false
    /// Otto's phone line (the Vapi assistant). Set in details; dialled with the phone app.
    @AppStorage("callNumber") private var callNumber = ""
    @Environment(\.openURL) private var openURL
    /// Shared with the composer, which lives in its own hosting controller (see KeyboardDock).
    let ui: ComposerUI
    private var focused: Bool { ui.focused }
    @State private var scroll = ScrollPosition(edge: .bottom)
    /// The thread's bottom margin; follows ui.bottomInset, but lags it while the keyboard closes.
    @State private var margin: CGFloat = 0
    /// Scroll offset from the top of the content.
    @State private var offsetY: CGFloat = 0

    private var lastMine: Message.ID? { store.messages.last(where: { $0.from == .me })?.id }

    /// "Read" once Otto has taken the message in (or answered after it); until then it
    /// may be sitting in his queue, which is "Delivered".
    private func receipt(for i: Int) -> Bool {
        store.messages[i].read == true || store.messages[(i + 1)...].contains { $0.from == .otto }
    }

    var body: some View {
        ScrollView {
                // Not lazy: rows materialised lazily went blank while UIKit animated the
                // thread's frame with the keyboard. A chat is short enough to lay out whole.
                VStack(spacing: 0) {
                    ForEach(Array(store.messages.enumerated()), id: \.element.id) { i, m in
                        let prev = i > 0 ? store.messages[i - 1] : nil
                        let next = i + 1 < store.messages.count ? store.messages[i + 1] : nil
                        let newBlock = prev.map { m.date.timeIntervalSince($0.date) > 3600 } ?? true
                        if newBlock { Stamp(date: m.date) }
                        Row(message: m,
                            quote: m.replyTo.flatMap { r in store.messages.first { $0.wireID == r } },
                            tail: next?.from != m.from || next.map { $0.date.timeIntervalSince(m.date) > 3600 } ?? true,
                            receipt: m.id == lastMine && m.pending != true ? receipt(for: i) : nil,
                            onTap: { store.tap($0, on: m.id) })
                            .padding(.top, newBlock ? 0 : (prev?.from == m.from ? 2 : 10))
                            .id(m.id)
                            // New bubbles grow out of their own tail corner, iMessage-style.
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.4, anchor: m.from == .me ? .bottomTrailing : .bottomLeading)
                                    .combined(with: .opacity)
                                    .combined(with: .offset(y: m.from == .me ? 24 : 0)),
                                removal: .opacity))
                    }
                    if store.ottoTyping {
                        Typing(status: store.ottoStatus).padding(.top, 10).id("typing")
                            .transition(.scale(scale: 0.5, anchor: .bottomLeading).combined(with: .opacity))
                    }
                }
                .animation(store.animated ? .spring(response: 0.38, dampingFraction: 0.72) : nil, value: store.messages.count)
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.ottoTyping)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
        // Pinned to the bottom as content grows (new bubbles, typing dots, the keyboard),
        // so nothing has to scroll after the fact and fight the insert animation.
        .scrollPosition($scroll)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        // The composer rides the keyboard's layout guide, so it follows a drag-to-dismiss.
        .scrollDismissesKeyboard(.interactively)
        // Tapping anywhere in the thread puts the keyboard away; buttons still win their own taps.
        .contentShape(.rect)
        .onTapGesture { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        // Your own send always comes back down, like Messages, even from far up the thread.
        .onChange(of: lastMine) { withAnimation(.snappy) { scroll.scrollTo(edge: .bottom) } }
        // What the composer and keyboard cover. A SwiftUI margin rather than a UIKit safe-area
        // inset: SwiftUI applied the inset in one jump and then scrolled after it on its own
        // curve, so the thread lurched. Now the margin and the scroll move together, on the
        // keyboard's curve.
        .contentMargins(.bottom, margin, for: .scrollContent)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { offsetY = $1 }
        .onChange(of: ui.bottomInset) { old, new in
            // A drag-to-dismiss, frame by frame: follow it, and never scroll under the finger.
            guard ui.insetAnimated else { margin = new; return }
            if new > old {
                withAnimation(ComposerUI.keyboard) { margin = new; scroll.scrollTo(edge: .bottom) }
            } else {
                // Shrinking the margin first clamps the offset in one frame (the snap). Slide the
                // thread down by the same amount on the keyboard's curve, then let the margin go.
                withAnimation(ComposerUI.keyboard, completionCriteria: .logicallyComplete) {
                    scroll.scrollTo(y: max(0, offsetY - (old - new)))
                } completion: { margin = ui.bottomInset }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: lastMine)
        .overlay { if store.messages.isEmpty && !store.ottoTyping { EmptyChat(asleep: store.asleep, connected: store.connected, lookingAtCursor: focused) } }
        .background(Color(.systemBackground))
        .safeAreaInset(edge: .top, spacing: 0) { header }
        // The header's fade, mirrored behind the composer: bubbles dissolve into the
        // edge instead of meeting a solid strip.
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Color(.systemBackground).opacity(0), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: ui.bottomInset + 24)
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showDetails) { DetailsView() }
        .fullScreenCover(isPresented: $webCall) { CallView() }
        .alert("Calling Otto", isPresented: $showCall) {
            Button("OK", role: .cancel) {}
        } message: { Text("Add Otto's phone number in details (tap Otto's name).") }
    }

    static func sideStoreInstall(_ ipa: String) -> URL? {
        var c = URLComponents()
        c.scheme = "sidestore"; c.host = "install"
        c.queryItems = [URLQueryItem(name: "url", value: ipa)]
        return c.url
    }

    private var header: some View {
        ZStack {
            HStack {
                if let u = store.update, let link = Self.sideStoreInstall(u.ipa) {
                    // SideStore downloads, re-signs and installs; it asks before replacing the app.
                    Button { openURL(link) } label: {
                        Label("Update", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 40)
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .tint(.accentColor)
                }
                Spacer()
                Button {
                    // Web call (free, over the internet) when Vapi is set up; the phone line otherwise.
                    let digits = callNumber.filter { $0.isNumber || $0 == "+" }
                    if CallManager.configured { webCall = true }
                    else if let url = URL(string: "tel:\(digits)"), !digits.isEmpty { openURL(url) }
                    else { showCall = true }
                } label: {
                    Image(systemName: "phone").font(.system(size: 17))
                        .frame(width: 40, height: 40)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
                .tint(.primary)
            }
            Button { showDetails = true } label: {
                VStack(spacing: 4) {
                    OttoAvatar(size: 56, thinking: store.ottoTyping, asleep: store.asleep, lookingAtCursor: focused)
                    HStack(spacing: 3) {
                        Text("Otto").font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
            }
            .tint(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .background(alignment: .top) {
            LinearGradient(colors: [Color(.systemBackground), Color(.systemBackground).opacity(0)],
                            startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        }
    }

}


/// The text box, mic and + menu. Hosted on its own and pinned to the keyboard by KeyboardDock.
/// Photos (camera, library, or pasted into the box) wait in the box as attachments
/// until you send, like Messages.
struct Composer: View {
    @Environment(OttoStore.self) private var store
    let ui: ComposerUI
    @State private var draft = ""
    @State private var focused = false
    @State private var attachments: [Attachment] = []
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var recorder = VoiceRecorder()

    struct Attachment: Identifiable { let id = UUID(); let image: UIImage }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
        HStack(alignment: .bottom, spacing: 8) {
            Menu {
                Button("Camera", systemImage: "camera") { showCamera = true }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button("Photos", systemImage: "photo.on.rectangle") { showLibrary = true }
            } label: {
                Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                    .frame(width: 36, height: 36)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .tint(.secondary)

            VStack(alignment: .leading, spacing: 0) {
                if let m = replying, recorder.started == nil { replyBar(m) }
                if !attachments.isEmpty && recorder.started == nil { strip }
                HStack(alignment: .bottom, spacing: 0) {
                    if let started = recorder.started {
                        Button { withAnimation(.snappy) { recorder.cancel() } } label: {
                            Image(systemName: "xmark").frame(width: 36, height: 36)
                        }
                        .tint(.secondary)
                        TimelineView(.periodic(from: started, by: 1)) { tl in
                            let s = Int(tl.date.timeIntervalSince(started))
                            Label(String(format: "%d:%02d", s / 60, s % 60), systemImage: "circle.fill")
                                .foregroundStyle(.red).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .transition(.opacity)
                        Button { withAnimation(.snappy) { if let url = recorder.stop() { store.sendVoice(url) } } } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.red)
                                .frame(width: 36, height: 36)
                        }
                    } else {
                        ComposerTextView(text: $draft, focused: $focused, placeholder: "Text Otto") { images in
                            withAnimation(.snappy) { attachments += images.map { Attachment(image: $0) } }
                        }
                        .transition(.opacity)
                        if !canSend {
                            Button { Task { await recorder.start() } } label: {
                                Image(systemName: "mic").frame(width: 36, height: 36)
                            }
                            .tint(.secondary)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        } else {
                            Button(action: send) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 28))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.blue)
                                    .frame(width: 36, height: 36)
                            }
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                        }
                    }
                }
            }
            .animation(.snappy(duration: 0.22), value: canSend)
            .animation(.snappy(duration: 0.22), value: recorder.started != nil)
            .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .onChange(of: focused) { ui.focused = focused }
        .onChange(of: draft) { ui.relayout() }
        .onChange(of: attachments.count) { ui.relayout() }
        .onChange(of: recorder.started != nil) { ui.relayout() }
        .onChange(of: store.replyingTo) { if store.replyingTo != nil { focused = true }; ui.relayout() }
        #if DEBUG
        // Layout checks without a keyboard or a server: `-growDraft` types, `-seedDraft`
        // fills the box, `-seedAttachments` adds two photos, `-keyboardDemo` loops focus.
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-seedAttachments") {
                attachments = [UIColor.systemOrange, .systemTeal].map { c in
                    Attachment(image: UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { ctx in c.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200)) })
                }
            }
            if args.contains("-growDraft") {
                for _ in 0..<40 { try? await Task.sleep(for: .milliseconds(120)); draft += "typing more words " }
            }
            if args.contains("-seedDraft") {
                draft = String(repeating: "a long draft that should make the box grow. ", count: 5)
            }
            guard args.contains("-keyboardDemo") else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2)); focused = true
                try? await Task.sleep(for: .seconds(2)); focused = false
            }
        }
        #endif
        .sensoryFeedback(.impact(weight: .medium), trigger: recorder.started != nil)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in withAnimation(.snappy) { attachments.append(Attachment(image: img)) } }.ignoresSafeArea()
        }
        .photosPicker(isPresented: $showLibrary, selection: $picked, maxSelectionCount: 10, matching: .images)
        .onChange(of: picked) {
            let items = picked
            guard !items.isEmpty else { return }
            picked = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        withAnimation(.snappy) { attachments.append(Attachment(image: img)) }
                    }
                }
            }
        }
    }

    private var replying: Message? { store.replyingTo.flatMap { id in store.messages.first { $0.id == id } } }

    /// What a swipe picked to answer, with an ✕ to drop it.
    private func replyBar(_ m: Message) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(m.from == .me ? "Replying to yourself" : "Replying to Otto").font(.system(size: 12, weight: .semibold))
                Text(m.text.isEmpty ? (m.image != nil ? "Photo" : "Voice message") : m.text)
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button { withAnimation(.snappy) { store.replyingTo = nil } } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14).padding(.top, 10)
        .transition(.opacity)
    }

    /// Thumbnails waiting to go, each with an ✕ to take it back out.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { a in
                    Image(uiImage: a.image).resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(.rect(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { withAnimation(.snappy) { attachments.removeAll { $0.id == a.id } } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.black.opacity(0.6))
                                    .font(.system(size: 20))
                            }
                            .padding(3)
                        }
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10).padding(.top, 10)
        }
    }

    /// Photos go first, each its own bubble; the text rides on the last one as its caption.
    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let photos = attachments
        guard !text.isEmpty || !photos.isEmpty else { return }
        for (i, a) in photos.enumerated() {
            store.sendPhoto(a.image, caption: i == photos.count - 1 ? text : "")
        }
        if photos.isEmpty { store.send(text) }
        withAnimation(.snappy) { attachments = [] }
        draft = ""
    }
}

/// UITextView rather than TextField, for one thing: pasting an image. It lands in the
/// composer as an attachment instead of being refused.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let placeholder: String
    let onImages: ([UIImage]) -> Void
    private static let maxLines: CGFloat = 6

    func makeUIView(context: Context) -> PastingTextView {
        let v = PastingTextView()
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.backgroundColor = .clear
        v.isScrollEnabled = false
        v.textContainerInset = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 4)
        v.textContainer.lineFragmentPadding = 0
        v.delegate = context.coordinator
        v.placeholder.text = placeholder
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateUIView(_ v: PastingTextView, context: Context) {
        v.onImages = onImages
        if v.text != text { v.text = text }
        v.placeholder.isHidden = !text.isEmpty
        if focused && !v.isFirstResponder { DispatchQueue.main.async { v.becomeFirstResponder() } }
        if !focused && v.isFirstResponder { DispatchQueue.main.async { v.resignFirstResponder() } }
    }

    /// Grows line by line up to six, then scrolls inside.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView v: PastingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 280
        let fit = v.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let cap = (v.font?.lineHeight ?? 22) * Self.maxLines + v.textContainerInset.top + v.textContainerInset.bottom
        v.isScrollEnabled = fit > cap
        return CGSize(width: width, height: min(fit, cap))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        init(_ p: ComposerTextView) { parent = p }
        func textViewDidChange(_ v: UITextView) {
            parent.text = v.text
            (v as? PastingTextView)?.placeholder.isHidden = !v.text.isEmpty
            if v.isScrollEnabled { v.scrollRangeToVisible(v.selectedRange) }   // past six lines, follow the caret
        }
        func textViewDidBeginEditing(_ v: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ v: UITextView) { if parent.focused { parent.focused = false } }
    }
}

final class PastingTextView: UITextView {
    var onImages: ([UIImage]) -> Void = { _ in }
    let placeholder = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.textColor = .placeholderText
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        addSubview(placeholder)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholder.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top,
                                   width: bounds.width - textContainerInset.left - textContainerInset.right,
                                   height: placeholder.intrinsicContentSize.height)
    }

    // Paste is offered when the clipboard holds an image, which a plain text view refuses.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) && UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let board = UIPasteboard.general
        if board.hasImages, let images = board.images, !images.isEmpty {
            onImages(images)
            return
        }
        super.paste(sender)
    }
}

// MARK: - Pieces (Unchanged)

private struct Stamp: View {
    let date: Date
    var body: some View {
        let day = Calendar.current.isDateInToday(date) ? "Today" : date.formatted(.dateTime.weekday(.wide))
        (Text(day).fontWeight(.semibold) + Text(" " + date.formatted(date: .omitted, time: .shortened)))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.top, 14).padding(.bottom, 8)
    }
}

private struct Row: View {
    @Environment(OttoStore.self) private var store
    let message: Message
    /// The message this one answers, shown small above the bubble.
    let quote: Message?
    let tail: Bool
    /// Under your newest message: true is "Read", false "Delivered", nil nothing.
    let receipt: Bool?
    let onTap: (ActionButton) -> Void
    @State private var swipe: CGFloat = 0
    @State private var selecting = false
    private var mine: Bool { message.from == .me }
    private static let tapbacks = ["❤️", "👍", "👎", "😂", "‼️", "❓"]
    /// How far a swipe has to pull before letting go means "reply".
    private static let replyAt: CGFloat = 60

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 6) {
            if let quote {
                Text(quote.text.isEmpty ? (quote.image != nil ? "Photo" : "Voice message") : quote.text)
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(.systemGray4)))
            }
            if let img = Thumbs.image(for: message) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 320)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
            }
            ForEach(message.files ?? [], id: \.id) { RemoteFileView(file: $0) }
            if let audio = message.audio { AudioChip(file: audio) }
            if message.image == nil || !message.text.isEmpty {
            (message.isVoice && message.audio == nil ? Text("\(Image(systemName: "waveform")) \(message.text.isEmpty ? "Voice message" : message.text)") : Text(message.text))
                .font(.system(size: 17))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(mine ? .white : .primary)
                .background(BubbleShape(mine: mine, tail: tail).fill(mine ? Color.blue : Color(.systemGray5)))
                .contentShape(.contextMenuPreview, BubbleShape(mine: mine, tail: false))
                // Double-tap: ❤️ straight away, no menu. Again takes it off.
                .onTapGesture(count: 2) { store.react("❤️", on: message.id) }
                .sensoryFeedback(.impact(weight: .light), trigger: message.reaction)
                .contextMenu {
                    // Palette: one row of emoji, like Messages. A plain ControlGroup caps at three
                    // across and stacks the rest down the menu.
                    ControlGroup {
                        ForEach(Self.tapbacks, id: \.self) { e in Button(e) { store.react(e, on: message.id) } }
                    }
                    .controlGroupStyle(.palette)
                    Button("Reply", systemImage: "arrowshape.turn.up.left") { store.replyingTo = message.id }
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
                    Button("Select Text", systemImage: "selection.pin.in.out") { selecting = true }
                }
                .sheet(isPresented: $selecting) {
                    SelectableText(text: message.text)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
                .overlay(alignment: mine ? .topLeading : .topTrailing) {
                    if let r = message.reaction { Tapback(emoji: r, mine: mine) }
                }
                .padding(.top, message.reaction == nil ? 0 : 14)
            }

            // Otto's buttons read as suggested replies: plain blue text, no chrome.
            if !message.buttons.isEmpty {
                HStack(spacing: 16) {
                    ForEach(message.buttons) { b in
                        Button(b.label) { onTap(b) }.font(.system(size: 15)).tint(.blue)
                    }
                }
                .padding(.leading, 12)
            }

            if message.pending == true {
                Text("Sending…").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            } else if let receipt {
                Group {
                    if receipt { Text("Read ").fontWeight(.semibold) + Text(message.date.formatted(date: .omitted, time: .shortened)) }
                    else { Text("Delivered").fontWeight(.semibold) }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.trailing, 4)
                .contentTransition(.opacity)
                .animation(.snappy, value: receipt)
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 64)
        // Swipe right to reply, as in Messages: the row follows the finger, an arrow
        // fills in behind it, and letting go past the mark picks it.
        .offset(x: swipe)
        .background(alignment: .leading) {
            Image(systemName: "arrowshape.turn.up.left.circle.fill")
                .font(.system(size: 24)).foregroundStyle(.secondary)
                .opacity(Double(swipe / Self.replyAt))
                .scaleEffect(swipe >= Self.replyAt ? 1.1 : 0.8)
                .offset(x: swipe - 32)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { g in
                    guard g.translation.width > 0, abs(g.translation.width) > abs(g.translation.height) * 1.5 else { return }
                    swipe = min(g.translation.width, Self.replyAt + 20)
                }
                .onEnded { _ in
                    if swipe >= Self.replyAt { store.replyingTo = message.id }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipe = 0 }
                }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: swipe >= Self.replyAt) { _, new in new }
    }
}

/// A photo or file Otto sent. Photos show inline; anything else opens in Quick Look.
private struct RemoteFileView: View {
    @Environment(OttoStore.self) private var store
    let file: RemoteFile
    @State private var data: Data?
    @State private var missing = false
    @State private var preview: URL?
    /// The thread lays out whole, so every row asks at once; fetch each file once.
    @MainActor private static var cache: [String: Data] = [:]

    var body: some View {
        Group {
            if file.kind == "image", let data, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 320)
                    .clipShape(.rect(cornerRadius: 18, style: .continuous))
                    .onTapGesture { open() }
            } else {
                Button(action: open) {
                    Label(missing ? "\(file.name) — no longer available" : file.name,
                          systemImage: file.kind == "image" ? "photo" : "doc")
                        .font(.system(size: 15)).lineLimit(1)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color(.systemGray5), in: .rect(cornerRadius: 18, style: .continuous))
                }
                .tint(.primary)
                .disabled(missing)
            }
        }
        .task(id: file.id) {
            if let hit = Self.cache[file.id] { data = hit; return }
            guard file.kind == "image" else { return }
            await load()
        }
        .quickLookPreview($preview)
    }

    private func load() async {
        if let d = await store.backend.file(file.id) { Self.cache[file.id] = d; data = d } else { missing = true }
    }

    private func open() {
        Task {
            if data == nil { await load() }
            guard let data else { return }
            let url = URL.temporaryDirectory.appending(path: file.name)
            try? data.write(to: url)
            preview = url
        }
    }
}

/// Otto's spoken reply: tap to play, tap again to stop. The words are in the bubble below.
private struct AudioChip: View {
    @Environment(OttoStore.self) private var store
    let file: RemoteFile
    private var player: AudioPlayer { .shared }

    var body: some View {
        let playing = player.playing == file.id
        Button {
            Task { await player.toggle(file.id) { await store.backend.file(file.id) } }
        } label: {
            Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill")
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.systemGray5), in: .capsule)
                .contentTransition(.symbolEffect(.replace))
        }
        .tint(.primary)
    }
}

@MainActor @Observable final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()
    /// The RemoteFile id playing now.
    private(set) var playing: String?
    @ObservationIgnored private var player: AVAudioPlayer?

    func toggle(_ id: String, load: () async -> Data?) async {
        if playing == id { stop(); return }
        stop()
        guard let data = await load(), let p = try? AVAudioPlayer(data: data) else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        p.delegate = self
        p.play()
        player = p
        playing = id
    }

    func stop() { player?.stop(); player = nil; playing = nil }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in if player === p { stop() } }
    }
}

/// Rounded bubble; the last one in a run gets a tail curling out of its bottom corner.
private struct BubbleShape: Shape {
    let mine: Bool
    let tail: Bool

    func path(in rect: CGRect) -> Path {
        let p = Path(roundedRect: rect, cornerRadius: 18, style: .continuous)
        guard tail else { return p }
        // Drawn for the left side, mirrored for yours. Union, not addPath: opposite
        var t = Path()
        let x = rect.minX
        t.move(to: CGPoint(x: x + 1, y: rect.maxY - 18))
        t.addCurve(to: CGPoint(x: x - 5, y: rect.maxY),
                    control1: CGPoint(x: x + 1, y: rect.maxY - 6), control2: CGPoint(x: x - 2, y: rect.maxY - 2))
        t.addCurve(to: CGPoint(x: x + 14, y: rect.maxY - 3),
                    control1: CGPoint(x: x + 1, y: rect.maxY + 1), control2: CGPoint(x: x + 9, y: rect.maxY - 1))
        t.addLine(to: CGPoint(x: x + 14, y: rect.maxY - 18))
        t.closeSubpath()
        if mine {
            t = t.applying(CGAffineTransform(translationX: rect.maxX + rect.minX, y: 0).scaledBy(x: -1, y: 1))
        }
        return p.union(t)
    }
}

private struct Tapback: View {
    let emoji: String
    let mine: Bool
    var body: some View {
        Text(emoji).font(.system(size: 13))
            .frame(width: 30, height: 30)
            .background(Color(.systemGray5), in: .circle)
            .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2.5))
            .offset(x: mine ? -14 : 14, y: -16)
    }
}

private struct Typing: View {
    /// What Otto is doing, shown beside the dots; nil is just the dots.
    let status: String?
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().frame(width: 8, height: 8).opacity(phase == i ? 0.85 : 0.35)
                }
            }
            if let status {
                Text(status)
                    .font(.system(size: 14))
                    .lineLimit(1).truncationMode(.middle)
                    .contentTransition(.opacity)
                    .id(status)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.snappy(duration: 0.25), value: status)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(BubbleShape(mine: false, tail: true).fill(Color(.systemGray5)))
        .padding(.trailing, 64)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation { phase = (phase + 1) % 3 }
            }
        }
    }
}

/// First run, or a cleared thread: Otto front and centre with one line of what to do.
private struct EmptyChat: View {
    let asleep: Bool
    let connected: Bool
    // *** ADDED PARAMETER HERE ***
    let lookingAtCursor: Bool
    
    private var line: String {
        if !connected { return "Can't reach the server. What you send goes out when it's back." }
        return "Say hi. Reminders, mail, plans: I'll keep track of the rest."
    }
    var body: some View {
        VStack(spacing: 14) {
            Text("Otto").font(.title2.weight(.semibold))
            Text(line)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                .contentTransition(.opacity)
        }
        .animation(.easeInOut, value: asleep)
        .allowsHitTesting(false)
    }
}

/// The system camera, for the composer's + menu.
private struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }
    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onPick(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Tap the mic to record, tap send to upload. AAC at 16 kHz mono: Whisper needs no more.
@MainActor @Observable
final class VoiceRecorder {
    private(set) var started: Date?
    private var recorder: AVAudioRecorder?

    func start() async {
        guard recorder == nil, await AVAudioApplication.requestRecordPermission() else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try? session.setActive(true)
        let url = URL.temporaryDirectory.appending(path: "voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue]
        guard let r = try? AVAudioRecorder(url: url, settings: settings), r.record() else { return }
        recorder = r
        started = .now
    }

    /// The finished file, or nil if nothing was recording.
    func stop() -> URL? {
        guard let r = recorder else { return nil }
        r.stop()
        recorder = nil
        started = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return r.url
    }

    func cancel() { if let url = stop() { try? FileManager.default.removeItem(at: url) } }
}

/// Decoded photos, so scrolling past one doesn't re-decode its JPEG on every frame.
private enum Thumbs {
    static let cache = NSCache<NSUUID, UIImage>()
    static func image(for m: Message) -> UIImage? {
        guard let data = m.image else { return nil }
        if let hit = cache.object(forKey: m.id as NSUUID) { return hit }
        guard let img = UIImage(data: data) else { return nil }
        cache.setObject(img, forKey: m.id as NSUUID)
        return img
    }
}

/// What the thread needs to know about the composer, across the two hosting controllers.
@Observable final class ComposerUI {
    var focused = false
    /// How much of the thread's bottom the composer covers.
    var bottomInset: CGFloat = 0
    /// UIKit's keyboard curve (curve 7) as a SwiftUI spring, so the thread moves with the keyboard.
    /// Whether the last inset change came from an animation (keyboard open/close, the box
    /// growing) rather than a drag-to-dismiss.
    @ObservationIgnored var insetAnimated = false
    static let keyboard = Animation.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)
    /// Asks the dock to re-measure the composer (a draft wrapped onto a new line).
    @ObservationIgnored var relayout: () -> Void = {}
}

/// The chat screen. UIKit only for layout: the composer is pinned to
/// `keyboardLayoutGuide`, which follows the keyboard frame by frame, including a
/// drag-to-dismiss — SwiftUI's keyboard safe area jumps there instead.
struct ChatScreen: UIViewControllerRepresentable {
    let store: OttoStore
    func makeUIViewController(context: Context) -> KeyboardDock { KeyboardDock(store: store) }
    func updateUIViewController(_ vc: KeyboardDock, context: Context) {}
}

final class KeyboardDock: UIViewController {
    private let thread: UIHostingController<AnyView>
    private let composer: UIHostingController<AnyView>
    private let ui: ComposerUI
    private var composerHeight: NSLayoutConstraint!

    init(store: OttoStore) {
        let ui = ComposerUI()
        self.ui = ui
        thread = UIHostingController(rootView: AnyView(ChatView(ui: ui).environment(store)))
        composer = UIHostingController(rootView: AnyView(Composer(ui: ui).environment(store)))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        for host in [thread, composer] {
            addChild(host)
            view.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.backgroundColor = .clear
            host.safeAreaRegions = .container   // the keyboard is handled here, not by SwiftUI
            host.didMove(toParent: self)
        }
        // Measured at the real width (intrinsic size measures unconstrained, so a long
        // draft never wrapped and the box stayed one line tall).
        composerHeight = composer.view.heightAnchor.constraint(equalToConstant: 52)
        ui.relayout = { [weak self] in DispatchQueue.main.async { self?.measureComposer(animated: true) } }
        NSLayoutConstraint.activate([
            thread.view.topAnchor.constraint(equalTo: view.topAnchor),
            // Full height: resizing the thread with the keyboard re-laid SwiftUI out at the
            // final size in one jump. The keyboard is an inset instead (below).
            thread.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            thread.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thread.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.view.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            composerHeight,
        ])
    }

    /// The thread scrolls under the composer (the glass needs something behind it), so
    /// its bottom inset is whatever the composer and keyboard cover.
    private func measureComposer(animated: Bool) {
        guard view.bounds.width > 0 else { return }
        let h = composer.sizeThatFits(in: CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
        guard abs(h - composerHeight.constant) > 0.5 else { return }
        composerHeight.constant = h
        if animated { UIView.animate(withDuration: 0.2) { self.view.layoutIfNeeded() } }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        measureComposer(animated: false)
        let covered = max(0, view.bounds.maxY - composer.view.frame.minY - view.safeAreaInsets.bottom)
        guard abs(ui.bottomInset - covered) > 0.5 else { return }
        // Inside the keyboard's animation block this runs once, with the final frame; a
        // drag-to-dismiss calls it every frame outside any block. ChatView animates the former.
        ui.insetAnimated = UIView.inheritedAnimationDuration > 0
        ui.bottomInset = covered
    }
}


/// A message's text with real selection handles, for copying part of it.
/// SwiftUI's `.textSelection` only offers the whole string on iOS.
private struct SelectableText: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.font = .systemFont(ofSize: 17)
        v.textContainerInset = UIEdgeInsets(top: 28, left: 16, bottom: 16, right: 16)
        v.dataDetectorTypes = [.link, .phoneNumber]
        v.text = text
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        if v.text != text { v.text = text }
    }
}
