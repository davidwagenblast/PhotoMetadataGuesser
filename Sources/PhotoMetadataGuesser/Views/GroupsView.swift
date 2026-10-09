import SwiftUI
import DateGuessCore

struct GroupsView: View {
    @Environment(AppState.self) private var state
    var goNext: () -> Void

    @State private var selectedGroupID: UUID?
    @State private var selectedPhotos: Set<String> = []
    @State private var filter: PhotoFilter = .ungrouped
    @State private var search = ""
    @State private var showingNewGroup = false
    @State private var newGroupName = ""
    @State private var suggestions: [GroupSuggestion] = []

    enum PhotoFilter: String, CaseIterable, Identifiable {
        case ungrouped = "Not in a group"
        case inGroup = "In this group"
        case all = "All undated"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            groupList
                .frame(width: 290)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    StepHeader(step: 2, title: "Group photos that go together",
                               subtitle: "Optional, but it really helps: photos from the same event or the same album are dated together, and anything you know (“Hawaii trip, summer ’78”) applies to all of them.",
                               systemImage: "square.stack.3d.up")
                    if let id = selectedGroupID, state.groups.contains(where: { $0.id == id }) {
                        GroupEditor(groupID: id, onDelete: { selectedGroupID = nil })
                    }
                }
                .padding([.horizontal, .top], 24)
                .padding(.bottom, 12)
                photoGrid
            }
        }
        .onAppear { suggestions = state.groupSuggestions() }
        .onChange(of: state.groups) { _, _ in suggestions = state.groupSuggestions() }
        .alert("New group", isPresented: $showingNewGroup) {
            TextField("Name (e.g. “Grandma’s 80th birthday”)", text: $newGroupName)
            Button("Create") {
                let g = state.createGroup(name: newGroupName.isEmpty ? "New group" : newGroupName, assetIDs: Array(orderedSelection))
                selectedGroupID = g.id
                selectedPhotos.removeAll()
                filter = .inGroup
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(selectedPhotos.count) photos will be added.")
        }
    }

    private var orderedSelection: [String] {
        state.undatedSorted.map(\.id).filter { selectedPhotos.contains($0) }
    }

    // MARK: Left column

    private var groupList: some View {
        List(selection: $selectedGroupID) {
            Section("Your groups") {
                if state.groups.isEmpty {
                    Text("No groups yet. Select photos on the right and click “New Group”, or accept a suggestion below.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(state.groups) { g in
                    HStack {
                        Image(systemName: g.kind == .sameEvent ? "calendar" : "square.stack.3d.up")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading) {
                            Text(g.name).lineLimit(1)
                            Text("\(g.assetIDs.count) photos\(g.hint.isEmpty ? "" : " · \(g.hint)")")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(g.id)
                }
            }
            if !suggestions.isEmpty {
                Section("Suggestions") {
                    ForEach(suggestions.prefix(40)) { s in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(s.title).lineLimit(1)
                            Text(s.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Button("Make Group") {
                                let g = state.createGroup(name: s.title, assetIDs: s.assetIDs, kind: s.kind)
                                selectedGroupID = g.id
                                filter = .inGroup
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                        .selectionDisabled()
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Next: People", action: goNext)
            }
            .padding(10)
        }
    }

    // MARK: Grid

    private var visiblePhotos: [UndatedPhoto] {
        let grouped = Set(state.groups.flatMap(\.assetIDs))
        let current = state.groups.first { $0.id == selectedGroupID }.map { Set($0.assetIDs) } ?? []
        return state.undatedSorted.filter { p in
            switch filter {
            case .ungrouped: if grouped.contains(p.id) { return false }
            case .inGroup: if !current.contains(p.id) { return false }
            case .all: break
            }
            if search.isEmpty { return true }
            return p.filename.localizedCaseInsensitiveContains(search)
                || p.albums.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var photoGrid: some View {
        let photos = visiblePhotos
        let selectedGroup = state.groups.first { $0.id == selectedGroupID }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(PhotoFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 360)
                TextField("Search filenames or albums", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Text("\(photos.count.formatted()) photos").foregroundStyle(.secondary)
                Button("Select All") { selectedPhotos.formUnion(photos.map(\.id)) }
                Button("Clear") { selectedPhotos.removeAll() }.disabled(selectedPhotos.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 10)], spacing: 10) {
                    ForEach(photos) { photo in
                        GroupPhotoCell(photo: photo, isSelected: selectedPhotos.contains(photo.id),
                                       groupName: state.groupFor(photo.id)?.name)
                            .onTapGesture {
                                if selectedPhotos.contains(photo.id) { selectedPhotos.remove(photo.id) }
                                else { selectedPhotos.insert(photo.id) }
                            }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 80)
            }
            .overlay {
                if photos.isEmpty {
                    ContentUnavailableView(filter == .inGroup ? "No photos in this group yet" : "No photos here",
                                           systemImage: "photo.on.rectangle",
                                           description: Text(filter == .inGroup ? "Switch to “Not in a group”, select photos and click “Add to Group”." : "Run a scan first, or change the filter."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selectedPhotos.isEmpty {
                    HStack(spacing: 12) {
                        Text("\(selectedPhotos.count) selected").fontWeight(.medium)
                        Spacer()
                        if let g = selectedGroup {
                            Button("Remove from “\(g.name)”") {
                                state.remove(Array(selectedPhotos), from: g.id)
                                selectedPhotos.removeAll()
                            }
                            Button("Add to “\(g.name)”") {
                                state.add(orderedSelection, to: g.id)
                                selectedPhotos.removeAll()
                            }
                        }
                        Button {
                            newGroupName = ""
                            showingNewGroup = true
                        } label: {
                            Label("New Group", systemImage: "plus.rectangle.on.rectangle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

struct GroupPhotoCell: View {
    var photo: UndatedPhoto
    var isSelected: Bool
    var groupName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AssetThumbnail(assetID: photo.id, side: 130, height: 110)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Theme.accent : .white)
                        .shadow(radius: 2)
                        .padding(6)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? Theme.accent : .clear, lineWidth: 3)
                )
            Text(photo.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let groupName {
                Text(groupName).font(.caption2).foregroundStyle(Theme.accent).lineLimit(1)
            }
        }
        .frame(width: 130)
        .contentShape(Rectangle())
        .help(photo.albums.isEmpty ? photo.filename : "\(photo.filename)\nAlbums: \(photo.albums.joined(separator: ", "))")
    }
}

/// Edits everything the user knows about one group.
struct GroupEditor: View {
    @Environment(AppState.self) private var state
    var groupID: UUID
    var onDelete: () -> Void

    /// Binds by ID (not index) so deleting or reordering groups can't point at the wrong one.
    private var groupBinding: Binding<PhotoGroup>? {
        guard let current = state.groups.first(where: { $0.id == groupID }) else { return nil }
        let state = self.state, id = groupID
        return Binding(
            get: { state.groups.first { $0.id == id } ?? current },
            set: { new in
                if let i = state.groups.firstIndex(where: { $0.id == id }) { state.groups[i] = new }
            })
    }

    var body: some View {
        if let group = groupBinding {
            Card {
                HStack(alignment: .firstTextBaseline) {
                    TextField("Group name", text: group.name)
                        .font(.title3.weight(.semibold))
                        .textFieldStyle(.plain)
                    Spacer()
                    Text("\(group.wrappedValue.assetIDs.count) photos").foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        onDelete()
                        state.groups.removeAll { $0.id == groupID }
                    } label: {
                        Label("Delete Group", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                Picker("These photos are from", selection: group.kind) {
                    ForEach(GroupKind.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                TextField("What do you know? e.g. “Lake Tahoe trip, late 70s” or “Mom’s high school years”",
                          text: group.hint, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                HStack(spacing: 14) {
                    Text("Years (if known):")
                    TextField("From", value: group.yearFrom, format: .number.grouping(.never))
                        .frame(width: 70)
                    Text("to")
                    TextField("To", value: group.yearTo, format: .number.grouping(.never))
                        .frame(width: 70)
                    Picker("Season", selection: group.season) {
                        Text("Unknown").tag(Season?.none)
                        ForEach(Season.allCases) { s in
                            Label(s.displayName, systemImage: s.symbolName).tag(Season?.some(s))
                        }
                    }
                    .frame(width: 180)
                }
                .textFieldStyle(.roundedBorder)
                peopleRow(group)
            }
        }
    }

    @ViewBuilder
    private func peopleRow(_ group: Binding<PhotoGroup>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Who’s in these photos?")
                Spacer()
                Menu {
                    if state.people.isEmpty {
                        Text("Add people in the People & Birthdays step first")
                    }
                    ForEach(state.people) { person in
                        Button(person.name) {
                            group.wrappedValue.people.append(GroupPersonHint(personID: person.id))
                        }
                    }
                } label: {
                    Label("Add Person", systemImage: "person.badge.plus")
                }
                .fixedSize()
            }
            ForEach(group.people) { $hint in
                HStack {
                    Image(systemName: "person.crop.circle").foregroundStyle(Theme.accent)
                    Text(state.people.first { $0.id == hint.personID }?.name ?? "Unknown person")
                    Text("about")
                        .foregroundStyle(.secondary)
                    TextField("age", value: $hint.approximateAge, format: .number)
                        .frame(width: 50)
                        .textFieldStyle(.roundedBorder)
                    Text("years old (optional)").foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        group.wrappedValue.people.removeAll { $0.id == hint.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}
