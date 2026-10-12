import SwiftUI
import UIKit

enum AppColors {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.055)
    static let surface = Color(red: 0.105, green: 0.105, blue: 0.105)
    static let raised = Color(red: 0.16, green: 0.16, blue: 0.16)
    static let accent = Color(uiColor: .systemRed)
    static let secondaryText = Color.white.opacity(0.62)
    static let mutedText = Color.white.opacity(0.42)

    static let posterPalettes: [[Color]] = [
        [Color(red: 0.37, green: 0.13, blue: 0.10), Color(red: 0.10, green: 0.11, blue: 0.19)],
        [Color(red: 0.17, green: 0.30, blue: 0.38), Color(red: 0.08, green: 0.12, blue: 0.20)],
        [Color(red: 0.55, green: 0.24, blue: 0.09), Color(red: 0.20, green: 0.11, blue: 0.11)],
        [Color(red: 0.19, green: 0.22, blue: 0.44), Color(red: 0.11, green: 0.10, blue: 0.24)],
        [Color(red: 0.35, green: 0.28, blue: 0.13), Color(red: 0.18, green: 0.12, blue: 0.10)],
        [Color(red: 0.17, green: 0.34, blue: 0.29), Color(red: 0.07, green: 0.17, blue: 0.19)],
        [Color(red: 0.38, green: 0.19, blue: 0.43), Color(red: 0.13, green: 0.10, blue: 0.27)],
        [Color(red: 0.12, green: 0.31, blue: 0.39), Color(red: 0.06, green: 0.12, blue: 0.20)]
    ]
}

enum AppTypography {
    static let brand = Font.system(size: 28, weight: .bold)
    static let heroTitle = Font.system(.largeTitle, design: .default).weight(.semibold)
    static let pageTitle = Font.system(.title, design: .default).weight(.semibold)
    static let sectionTitle = Font.system(.title3, design: .default).weight(.semibold)
    static let cardTitle = Font.system(.subheadline, design: .default).weight(.semibold)
}

struct BrandWordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            Text("Rez")
                .foregroundStyle(.white)
            Text("ka")
                .foregroundStyle(AppColors.accent)
        }
        .font(compact ? .system(size: 22, weight: .bold) : AppTypography.brand)
        .tracking(-0.8)
        .accessibilityLabel("Rezka")
    }
}

struct PosterPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 1.035 : 1)
            .opacity(configuration.isPressed ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.42), value: configuration.isPressed)
    }
}

struct PremiumControlPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: configuration.isPressed)
    }
}

extension View {
    func posterPressFeedback() -> some View {
        buttonStyle(PosterPressStyle())
            .focusEffectDisabled()
            .simultaneousGesture(TapGesture().onEnded {
                let feedback = UIImpactFeedbackGenerator(style: .light)
                feedback.prepare()
                feedback.impactOccurred()
            })
    }

    func premiumTapFeedback() -> some View {
        buttonStyle(PremiumControlPressStyle())
            .focusEffectDisabled()
            .simultaneousGesture(TapGesture().onEnded {
                let feedback = UIImpactFeedbackGenerator(style: .light)
                feedback.prepare()
                feedback.impactOccurred()
            })
    }
}

struct ArtworkView: View {
    @Environment(AppModel.self) private var model
    let item: MediaItem
    var showTitle = false
    var alignment: Alignment = .center
    var useOriginal = false

    private var palette: [Color] {
        AppColors.posterPalettes[abs(item.paletteIndex) % AppColors.posterPalettes.count]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: palette,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(.white.opacity(0.075))
                    .frame(width: geometry.size.width * 0.86)
                    .offset(x: geometry.size.width * 0.35, y: -geometry.size.height * 0.42)
                    .blur(radius: 1)

                Circle()
                    .stroke(.white.opacity(0.11), lineWidth: 1)
                    .frame(width: geometry.size.width * 0.72)
                    .offset(x: geometry.size.width * 0.31, y: -geometry.size.height * 0.37)

                Image(systemName: item.symbol)
                    .font(.system(size: min(geometry.size.width * 0.32, 68), weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.76))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)

                if let posterURL = (useOriginal ? model.artworkItem(for: item) : model.previewArtworkItem(for: item)).posterURL {
                    CachedArtwork(url: posterURL, transaction: Transaction(animation: .easeInOut(duration: 0.24)), keepsPreviousImageWhileLoading: true) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill().transition(.opacity)
                        } else if phase.error != nil {
                            Color.clear
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: alignment)
                    .clipped()
                    .accessibilityHidden(true)
                }

                if showTitle {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.75)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    Text(item.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .lineLimit(2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .task(id: item.id) {
            if !useOriginal { await model.preparePreviewArtwork(for: item) }
        }
    }
}

struct MediaCard: View {
    let item: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topTrailing) {
                ArtworkView(item: item)
                    .aspectRatio(0.72, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(item.kind.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.58), in: Capsule())
                    .padding(8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.09), lineWidth: 1)
            }

            Text(item.title)
                .font(AppTypography.cardTitle)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)

            HStack(spacing: 8) {
                if let year = item.year {
                    Text(String(year))
                        .foregroundStyle(AppColors.secondaryText)
                }
                Text(item.genre)
                    .foregroundStyle(AppColors.mutedText)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeading: View {
    let title: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(AppTypography.sectionTitle)
                .foregroundStyle(.white)

            Spacer()

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppColors.accent)
            }
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(icon: String, title: String, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(AppColors.accent)
                .frame(width: 72, height: 72)
                .background(AppColors.accent.opacity(0.11), in: Circle())

            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(AppColors.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(AppColors.accent, in: Capsule())
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 54)
    }
}

struct MediaGrid: View {
    let items: [MediaItem]
    var onSelect: ((MediaItem) -> Void)?

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
            ForEach(items) { item in
                if let onSelect {
                    Button { onSelect(item) } label: { MediaCard(item: item) }
                        .posterPressFeedback()
                } else {
                    NavigationLink { DetailView(item: item) } label: { MediaCard(item: item) }
                        .posterPressFeedback()
                        .accessibilityIdentifier("catalogue-title-\(item.id)")
                }
            }
        }
    }
}

struct AppErrorAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Please try again.")
        }
    }
}

extension View {
    func appErrorAlert() -> some View { modifier(AppErrorAlert()) }
}
