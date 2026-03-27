import SwiftUI
import SwiftData

struct SidebarView: View {
    @Query(sort: \Meeting.date, order: .reverse) private var meetings: [Meeting]
    @Binding var selectedMeeting: Meeting?
    var onSelectMeeting: ((Meeting) -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        List(selection: $selectedMeeting) {
            if meetings.isEmpty {
                Text("No meetings yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 40)
            } else {
                ForEach(meetings) { meeting in
                    Button {
                        onSelectMeeting?(meeting)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(meeting.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(meeting.date, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .tag(meeting)
                }
            }
        }
        .listStyle(.sidebar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    // TODO: Start recording via sidebar
                }) {
                    Label("Record", systemImage: "record.circle")
                }
                .help("Start a new recording")
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    onOpenSettings?()
                } label: {
                    Label("Settings", systemImage: "gear")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Spacer()
            }
            .background(.bar)
        }
    }
}
