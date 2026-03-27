import SwiftUI
import UIKit

// MARK: - Mac OS X Leopard Color Palette

extension Color {
    static let leopardToolbar = Color(red: 0.69, green: 0.72, blue: 0.76)       // brushed metal grey
    static let leopardToolbarDark = Color(red: 0.55, green: 0.58, blue: 0.62)
    static let leopardSidebar = Color(red: 0.82, green: 0.84, blue: 0.87)
    static let leopardStripe1 = Color(red: 0.93, green: 0.94, blue: 0.96)       // alternating row
    static let leopardStripe2 = Color.white
    static let leopardAccent = Color(red: 0.2, green: 0.4, blue: 0.85)          // aqua blue
    static let leopardSelection = Color(red: 0.25, green: 0.5, blue: 0.95)
    static let leopardBubbleUser = Color(red: 0.22, green: 0.47, blue: 0.95)    // aqua bubble
    static let leopardBubbleBot = Color(red: 0.88, green: 0.89, blue: 0.91)     // silver
    static let leopardWindow = Color(red: 0.92, green: 0.93, blue: 0.95)
    static let leopardPinstripe = Color(red: 0.85, green: 0.86, blue: 0.88)
}

// MARK: - Brushed Metal Background

struct BrushedMetalBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.75, green: 0.78, blue: 0.82),
                Color(red: 0.68, green: 0.71, blue: 0.75),
                Color(red: 0.72, green: 0.75, blue: 0.79),
                Color(red: 0.65, green: 0.68, blue: 0.72),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Aqua Button Style

struct AquaButtonStyle: ButtonStyle {
    var color: Color = .leopardAccent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.5),
                                    Color.white.opacity(0.0),
                                ],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color.black.opacity(0.3), lineWidth: 0.5)
                }
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}

// MARK: - Window Title Bar

struct LeopardTitleBar: View {
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.80, green: 0.82, blue: 0.85),
                    Color(red: 0.68, green: 0.70, blue: 0.73),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(spacing: 6) {
                Image("Logo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(red: 0.2, green: 0.2, blue: 0.2))
            }

            // Traffic lights
            HStack(spacing: 7) {
                Circle().fill(.red).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.red.opacity(0.5), lineWidth: 0.5))
                Circle().fill(.yellow).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.yellow.opacity(0.5), lineWidth: 0.5))
                Circle().fill(.green).frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(Color.green.opacity(0.5), lineWidth: 0.5))
                Spacer()
            }
            .padding(.leading, 12)
        }
        .frame(height: 22)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.15))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Pinstripe Background

struct PinstripeBackground: View {
    var body: some View {
        Color.leopardWindow
    }
}

// MARK: - Leopard Section Header

struct LeopardSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(red: 0.4, green: 0.42, blue: 0.45))
                .tracking(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            LinearGradient(
                colors: [Color.leopardSidebar, Color.leopardSidebar.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Glossy Tab Bar (Dock-inspired)

struct LeopardTabBar: View {
    @Binding var selectedTab: Int
    let tabs: [(String, String)] // (label, systemImage)

    /// Map tab labels to dock icon asset names
    private func dockIcon(for label: String) -> String? {
        switch label {
        case "Agent": return "dock_agent"
        case "Models": return "dock_models"
        case "Terminal": return "dock_Terminal"
        case "Files": return "dock_files"
        case "Settings": return "dock_settings"
        default: return nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dock shelf background
            dockShelf

            // Icons row
            HStack(spacing: 0) {
                ForEach(tabs.indices, id: \.self) { i in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedTab = i
                        }
                    } label: {
                        VStack(spacing: 1) {
                            // Dock icon
                            if let iconName = dockIcon(for: tabs[i].0) {
                                Image(iconName)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: selectedTab == i ? 48 : 42,
                                           height: selectedTab == i ? 48 : 42)
                                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                                    .offset(y: selectedTab == i ? -6 : 0)
                            } else {
                                Image(systemName: tabs[i].1)
                                    .font(.system(size: 28))
                                    .frame(width: 42, height: 42)
                                    .foregroundColor(.white)
                            }

                            // Label
                            Text(tabs[i].0)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                                .offset(y: selectedTab == i ? -4 : 0)

                            // Active indicator dot
                            Circle()
                                .fill(selectedTab == i ? Color.white : Color.clear)
                                .frame(width: 4, height: 4)
                                .offset(y: selectedTab == i ? -3 : 0)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 14)
        }
    }

    private var dockShelf: some View {
        ZStack(alignment: .top) {
            // Main shelf body — frosted glass look
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.25),
                            Color.white.opacity(0.08),
                            Color.black.opacity(0.3),
                            Color.black.opacity(0.5),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 82)
                .padding(.horizontal, 4)
                .overlay(
                    // Top glass highlight
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                        .padding(.horizontal, 4)
                )
                .background(
                    // Dark base behind the glass
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                        .padding(.horizontal, 4)
                )
        }
        .padding(.bottom, 0)
    }
}

// MARK: - Leopard List Style (transparent over wallpaper)

/// A UIView that walks its ancestor hierarchy and clears all background colors.
/// SwiftUI's List sets opaque backgrounds programmatically after creation,
/// overriding appearance proxies. This view actively clears them on every layout pass.
private class ClearBackgroundUIView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        clearAncestorBackgrounds()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clearAncestorBackgrounds()
    }

    private func clearAncestorBackgrounds() {
        var current: UIView? = self
        while let view = current {
            if view.backgroundColor != nil && view.backgroundColor != .clear {
                view.backgroundColor = .clear
            }
            current = view.superview
        }
    }
}

/// SwiftUI wrapper that injects the background-clearing UIView into the hierarchy.
struct ClearListBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = ClearBackgroundUIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

extension View {
    /// Makes a List + NavigationStack transparent so the Leopard wallpaper shows through.
    func leopardListStyle() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(ClearListBackground())
            .toolbarBackground(.hidden, for: .navigationBar)
            .environment(\.colorScheme, .light)
    }
}

/// Call from PegasusApp.init() to set global transparent UIKit backgrounds
/// BEFORE any views are created
enum LeopardAppearance {
    static var isConfigured = false

    static func configureOnce() {
        guard !isConfigured else { return }
        isConfigured = true

        // Transparent navigation bar with bold white text
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        navAppearance.titleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.boldSystemFont(ofSize: 17)
        ]
        navAppearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.boldSystemFont(ofSize: 34)
        ]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        UINavigationBar.appearance().tintColor = .white
    }
}

// MARK: - Aurora Background (Leopard wallpaper)

struct AuroraBackground: View {
    var dimmed: Bool = false

    var body: some View {
        Image("Background")
            .resizable()
            .aspectRatio(contentMode: .fill)
            .overlay(
                dimmed
                    ? Color.black.opacity(0.3)
                    : Color.clear
            )
            .ignoresSafeArea()
    }
}

// MARK: - Pegasus Logo

struct PegasusLogo: View {
    var size: CGFloat = 120

    var body: some View {
        Image("Logo")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
    }
}

// MARK: - Thinking Animation

struct ThinkingIndicator: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        AgentStatusIndicator(phase: .thinking, status: "Reasoning...")
    }
}

struct AgentStatusIndicator: View {
    let phase: AgentPhase
    let status: String
    @State private var animPhase: CGFloat = 0

    private var icon: String {
        switch phase {
        case .thinking: return "brain.head.profile"
        case .toolCall: return "gearshape.2.fill"
        case .toolResult: return "checkmark.circle.fill"
        case .searching: return "magnifyingglass"
        case .fetching: return "globe"
        }
    }

    private var accentColor: Color {
        switch phase {
        case .thinking: return Color.leopardAccent
        case .toolCall: return Color(red: 0.5, green: 0.4, blue: 0.8)
        case .toolResult: return Color(red: 0.3, green: 0.6, blue: 0.4)
        case .searching: return Color(red: 0.2, green: 0.5, blue: 0.8)
        case .fetching: return Color(red: 0.2, green: 0.5, blue: 0.8)
        }
    }

    private var displayStatus: String {
        status.isEmpty ? "Thinking..." : status
    }

    var body: some View {
        HStack(spacing: 10) {
            // Animated icon
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)

                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(accentColor)
                    .symbolEffect(.pulse, options: .repeating)
            }

            VStack(alignment: .leading, spacing: 2) {
                // Status text
                Text(displayStatus)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(red: 0.3, green: 0.3, blue: 0.4))
                    .lineLimit(1)
                    .contentTransition(.numericText())

                // Animated progress bar
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(accentColor.opacity(0.15))
                        .frame(height: 3)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(accentColor.opacity(0.5))
                                .frame(width: geo.size.width * 0.3, height: 3)
                                .offset(x: geo.size.width * 0.7 * animPhase)
                        }
                        .clipped()
                }
                .frame(height: 3)
                .frame(maxWidth: 140)
                .clipped()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(red: 0.94, green: 0.95, blue: 0.97))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(accentColor.opacity(0.15), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .onAppear { startAnimation() }
        .onChange(of: phase) {
            animPhase = 0
            startAnimation()
        }
        .onChange(of: status) {
            // Restart if animation died
            if animPhase == 0 || animPhase == 1 {
                animPhase = 0
                startAnimation()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: phase)
    }

    private func startAnimation() {
        // Small delay ensures SwiftUI processes the reset to 0 before starting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                animPhase = 1
            }
        }
    }
}

// MARK: - Thinking Bubble (collapsible reasoning content)

struct ThinkingBubble: View {
    let content: String
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 11))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple.opacity(0.7), .blue.opacity(0.6)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Text("Reasoning")
                        .font(.system(size: 11, weight: .medium))
                    Text("(\(content.count) chars)")
                        .font(.system(size: 9))
                        .foregroundColor(Color(red: 0.6, green: 0.6, blue: 0.65))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundColor(Color(red: 0.45, green: 0.45, blue: 0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }

            if isExpanded {
                Divider()
                    .background(Color.purple.opacity(0.1))

                ScrollView {
                    Text(content)
                        .font(.system(size: 12))
                        .foregroundColor(Color(red: 0.35, green: 0.35, blue: 0.42))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 200)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.94, blue: 0.98),
                            Color(red: 0.93, green: 0.93, blue: 0.97),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.2), Color.blue.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.5
                        )
                )
        )
        .shadow(color: .purple.opacity(0.06), radius: 3, y: 1)
        .frame(maxWidth: 300, alignment: .leading)
    }
}

// MARK: - Markdown Text (renders **bold**, *italic*, `code`, and bullet points)

struct MarkdownText: View {
    let text: String
    let baseColor: Color

    init(_ text: String, baseColor: Color = .primary) {
        self.text = text
        self.baseColor = baseColor
    }

    var body: some View {
        Text(parseMarkdown(text))
            .font(.system(size: 14))
    }

    private func parseMarkdown(_ input: String) -> AttributedString {
        var result = AttributedString()
        let lines = input.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockLines: [String] = []

        for (lineIdx, line) in lines.enumerated() {
            // Handle fenced code blocks (``` or ```language)
            if line.hasPrefix("```") {
                if inCodeBlock {
                    // End of code block - render collected lines
                    if !codeBlockLines.isEmpty {
                        if result.characters.count > 0 {
                            result.append(AttributedString("\n"))
                        }
                        let codeText = codeBlockLines.joined(separator: "\n")
                        var attr = AttributedString(codeText)
                        attr.font = .system(size: 12, design: .monospaced)
                        attr.foregroundColor = Color(red: 0.9, green: 0.9, blue: 0.85)
                        attr.backgroundColor = Color(red: 0.15, green: 0.15, blue: 0.18)
                        result.append(attr)
                        codeBlockLines = []
                    }
                    inCodeBlock = false
                } else {
                    // Start of code block
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBlockLines.append(line)
                continue
            }

            if lineIdx > 0 {
                result.append(AttributedString("\n"))
            }

            var processedLine = line

            // Handle numbered lists (1. 2. 3. etc)
            let numberedPattern = processedLine
            if let dotIdx = numberedPattern.firstIndex(of: "."),
               dotIdx > numberedPattern.startIndex,
               numberedPattern[numberedPattern.startIndex..<dotIdx].allSatisfy({ $0.isNumber }),
               numberedPattern.index(after: dotIdx) < numberedPattern.endIndex,
               numberedPattern[numberedPattern.index(after: dotIdx)] == " " {
                let prefix = String(processedLine[processedLine.startIndex...dotIdx])
                var num = AttributedString("  \(prefix) ")
                num.foregroundColor = baseColor
                result.append(num)
                processedLine = String(processedLine[processedLine.index(dotIdx, offsetBy: 2)...])
            }
            // Handle bullet points
            else if processedLine.hasPrefix("- ") || processedLine.hasPrefix("• ") {
                var bullet = AttributedString("  •  ")
                bullet.foregroundColor = baseColor
                result.append(bullet)
                processedLine = String(processedLine.dropFirst(2))
            } else if processedLine.hasPrefix("* ") {
                var bullet = AttributedString("  •  ")
                bullet.foregroundColor = baseColor
                result.append(bullet)
                processedLine = String(processedLine.dropFirst(2))
            }

            // Handle headers
            if processedLine.hasPrefix("### ") {
                var header = AttributedString(String(processedLine.dropFirst(4)))
                header.font = .system(size: 14, weight: .bold)
                header.foregroundColor = baseColor
                result.append(header)
                continue
            } else if processedLine.hasPrefix("## ") {
                var header = AttributedString(String(processedLine.dropFirst(3)))
                header.font = .system(size: 15, weight: .bold)
                header.foregroundColor = baseColor
                result.append(header)
                continue
            } else if processedLine.hasPrefix("# ") {
                var header = AttributedString(String(processedLine.dropFirst(2)))
                header.font = .system(size: 16, weight: .bold)
                header.foregroundColor = baseColor
                result.append(header)
                continue
            }

            // Parse inline markdown: **bold**, *italic*, `code`
            result.append(parseInline(processedLine))
        }

        // Handle unclosed code block
        if inCodeBlock && !codeBlockLines.isEmpty {
            result.append(AttributedString("\n"))
            let codeText = codeBlockLines.joined(separator: "\n")
            var attr = AttributedString(codeText)
            attr.font = .system(size: 12, design: .monospaced)
            attr.foregroundColor = Color(red: 0.9, green: 0.9, blue: 0.85)
            attr.backgroundColor = Color(red: 0.15, green: 0.15, blue: 0.18)
            result.append(attr)
        }

        return result
    }

    private func parseInline(_ text: String) -> AttributedString {
        var result = AttributedString()
        var i = text.startIndex

        while i < text.endIndex {
            // **bold**
            if text[i] == "*",
               text.index(after: i) < text.endIndex,
               text[text.index(after: i)] == "*" {
                let start = text.index(i, offsetBy: 2)
                if let endRange = text.range(of: "**", range: start..<text.endIndex) {
                    let boldText = String(text[start..<endRange.lowerBound])
                    var attr = AttributedString(boldText)
                    attr.font = .system(size: 14, weight: .bold)
                    attr.foregroundColor = baseColor
                    result.append(attr)
                    i = endRange.upperBound
                    continue
                }
            }

            // *italic*
            if text[i] == "*" {
                let start = text.index(after: i)
                if start < text.endIndex,
                   let endIdx = text[start...].firstIndex(of: "*") {
                    let italicText = String(text[start..<endIdx])
                    if !italicText.isEmpty && !italicText.contains("\n") {
                        var attr = AttributedString(italicText)
                        attr.font = .system(size: 14).italic()
                        attr.foregroundColor = baseColor
                        result.append(attr)
                        i = text.index(after: endIdx)
                        continue
                    }
                }
            }

            // `code`
            if text[i] == "`" {
                let start = text.index(after: i)
                if start < text.endIndex,
                   let endIdx = text[start...].firstIndex(of: "`") {
                    let codeText = String(text[start..<endIdx])
                    var attr = AttributedString(codeText)
                    attr.font = .system(size: 13, design: .monospaced)
                    attr.foregroundColor = Color(red: 0.8, green: 0.2, blue: 0.2)
                    attr.backgroundColor = Color(red: 0.95, green: 0.93, blue: 0.93)
                    result.append(attr)
                    i = text.index(after: endIdx)
                    continue
                }
            }

            // Plain character
            var plain = AttributedString(String(text[i]))
            plain.font = .system(size: 14)
            plain.foregroundColor = baseColor
            result.append(plain)
            i = text.index(after: i)
        }

        return result
    }
}

// MARK: - Leopard Text Field

struct LeopardTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 13))
            .foregroundColor(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.3)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
    }
}
