import SwiftUI

struct CoreGridView: View {
    let cores: [CoreLoad]

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 72), spacing: 10)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(cores) { core in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(core.label)
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(core.active.percentText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    MeterBar(value: core.active, height: 7)
                }
                .padding(10)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
