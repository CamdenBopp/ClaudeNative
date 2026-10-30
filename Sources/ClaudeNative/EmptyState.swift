import SwiftUI

/// A message in place of a list or a file. ContentUnavailableView draws its
/// title and description in the system's secondary color, which measured
/// 3.03:1 on screen in the light sidebar; here the title is full label
/// color and the description the quiet label color.
struct EmptyState: View {
    let title: String
    let systemImage: String
    var description: String?

    init(_ title: String, systemImage: String, description: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.primary)
        } description: {
            if let description {
                Text(description)
                    .foregroundStyle(Color(nsColor: Theme.quietLabel))
            }
        }
    }
}
