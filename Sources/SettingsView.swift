import SwiftUI

/// Settings window: default scan options, how safety works, and the donate button.
struct SettingsView: View {
    @AppStorage("minSizeKB") private var minSizeKB = 100
    @AppStorage("includeHidden") private var includeHidden = false
    @AppStorage("includePackages") private var includePackages = false
    @AppStorage("keepRule") private var rule: KeepRule = .oldest

    var body: some View {
        Form {
            Section("Scan defaults") {
                Stepper("Minimum file size: \(minSizeKB) KB", value: $minSizeKB, in: 0...10_000_000, step: 100)
                Toggle("Include hidden files", isOn: $includeHidden)
                Toggle("Include packages (apps, Photos library)", isOn: $includePackages)
                Picker("Auto-select rule", selection: $rule) {
                    ForEach(KeepRule.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Safety") {
                Text("At least one copy in every group is always kept, and files are moved to the Trash so they can be restored. Symbolic links, aliases, hard links and empty files are never reported.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("If macOS asks for access to a folder such as Desktop or Documents, allow it so TwinFileSweep can read it. You can change this later in System Settings › Privacy & Security › Files and Folders.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("TwinFileSweep is free and open source.")
                    Spacer()
                    Button("Support / Donate ❤️") { Support.open() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}
