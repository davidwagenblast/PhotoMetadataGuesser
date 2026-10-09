import PhotosUI
import SwiftUI
import DateGuessCore

struct PeopleView: View {
    @Environment(AppState.self) private var state
    var goNext: () -> Void
    @State private var selectedID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selectedID) {
                Section("People") {
                    if state.people.isEmpty {
                        Text("Nobody yet — add the people who show up most in your old photos.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(state.people) { person in
                        HStack(spacing: 10) {
                            if let ref = person.referenceAssetIDs.first {
                                AssetThumbnail(assetID: ref, side: 30, cornerRadius: 15)
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(Theme.blush)
                            }
                            VStack(alignment: .leading) {
                                Text(person.name.isEmpty ? "Unnamed" : person.name)
                                Text("Born \(String(person.birthYear))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(person.id)
                    }
                }
            }
            .frame(width: 260)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button {
                        let p = PersonInfo(name: "", birthYear: 1960)
                        state.people.append(p)
                        selectedID = p.id
                    } label: {
                        Label("Add Person", systemImage: "person.badge.plus")
                    }
                    Spacer()
                    Button("Next: Estimate", action: goNext)
                }
                .padding(10)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    StepHeader(step: 3, title: "People and birthdays",
                               subtitle: "Optional. Tell us who appears in your photos and when they were born. When we spot them, their age in the picture tells us the year — the way you’d say “Dad looks about ten here, so it’s 1962.”",
                               systemImage: "person.2")
                    if let id = selectedID, state.people.contains(where: { $0.id == id }) {
                        PersonEditor(personID: id, onDelete: { selectedID = nil })
                    } else {
                        Card(title: "How people help", systemImage: "lightbulb") {
                            Text("• With Claude visual analysis on, your reference photos are used to recognize each person and judge their age in every photo.")
                            Text("• In Group Photos, you can say who’s in a group and roughly how old they are — that works even without Claude.")
                            Text("• Someone can’t appear in a photo taken before they were born, so their birth year is a firm lower limit.")
                        }
                        .font(.callout)
                    }
                }
                .padding(28)
                .frame(maxWidth: 860, alignment: .leading)
            }
        }
    }
}

struct PersonEditor: View {
    @Environment(AppState.self) private var state
    var personID: UUID
    var onDelete: () -> Void
    @State private var pickerItems: [PhotosPickerItem] = []

    private var personBinding: Binding<PersonInfo>? {
        guard let current = state.people.first(where: { $0.id == personID }) else { return nil }
        let state = self.state, id = personID
        return Binding(
            get: { state.people.first { $0.id == id } ?? current },
            set: { new in
                if let i = state.people.firstIndex(where: { $0.id == id }) { state.people[i] = new }
            })
    }

    var body: some View {
        if let person = personBinding {
            Card {
                HStack {
                    TextField("Name", text: person.name)
                        .font(.title2.weight(.semibold))
                        .textFieldStyle(.plain)
                    Spacer()
                    Button(role: .destructive) {
                        onDelete()
                        state.people.removeAll { $0.id == personID }
                        for i in state.groups.indices { state.groups[i].people.removeAll { $0.personID == personID } }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
                HStack(spacing: 12) {
                    Text("Born in")
                    TextField("Year", value: person.birthYear, format: .number.grouping(.never))
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                    Picker("Month", selection: person.birthMonth) {
                        Text("Month unknown").tag(Int?.none)
                        ForEach(1...12, id: \.self) { m in
                            Text(DateEstimate.monthNames[m - 1]).tag(Int?.some(m))
                        }
                    }
                    .frame(width: 220)
                }
                TextField("Notes for yourself (optional)", text: person.notes)
                    .textFieldStyle(.roundedBorder)
            }

            Card(title: "Reference photos", systemImage: "person.crop.square") {
                Text("Pick one or two photos where \(person.wrappedValue.name.isEmpty ? "this person" : person.wrappedValue.name)’s face is clear. Photos that already have a correct date are best — they show what they looked like at a known age.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(person.wrappedValue.referenceAssetIDs, id: \.self) { id in
                        AssetThumbnail(assetID: id, side: 110)
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    person.wrappedValue.referenceAssetIDs.removeAll { $0 == id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(.white, .black.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                                .padding(4)
                            }
                    }
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: 2, matching: .images, photoLibrary: .shared()) {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.title)
                            Text("Add")
                        }
                        .frame(width: 110, height: 110)
                        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                    }
                    .buttonStyle(.plain)
                }
                .onChange(of: pickerItems) { _, items in
                    let ids = items.compactMap(\.itemIdentifier)
                    guard !ids.isEmpty else { return }
                    var refs = person.wrappedValue.referenceAssetIDs
                    for id in ids where !refs.contains(id) { refs.append(id) }
                    person.wrappedValue.referenceAssetIDs = refs
                    pickerItems = []
                }
                if !state.settings.ai.enabled {
                    Label("Reference photos are only used when Claude visual analysis is turned on (Settings). Birth years still help through your groups.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
