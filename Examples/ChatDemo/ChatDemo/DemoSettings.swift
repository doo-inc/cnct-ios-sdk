import CNCTUI
import SwiftUI

enum DemoLanguage: String, CaseIterable, Identifiable {
  case auto, en, ar
  var id: String { rawValue }

  var chat: CnctChatLanguage {
    switch self {
    case .auto: return .auto
    case .en: return .en
    case .ar: return .ar
    }
  }

  var label: String {
    switch self {
    case .auto: return "Device"
    case .en: return "English"
    case .ar: return "العربية"
    }
  }
}

enum DemoAppearance: String, CaseIterable, Identifiable {
  /// Whatever the inbox's console settings say, then the device.
  case console, system, light, dark
  var id: String { rawValue }

  var chat: CnctChatAppearance? {
    switch self {
    case .console: return nil
    case .system: return .system
    case .light: return .light
    case .dark: return .dark
    }
  }

  var label: String {
    switch self {
    case .console: return "From the console"
    case .system: return "Device"
    case .light: return "Light"
    case .dark: return "Dark"
    }
  }
}

/// The switches the demo exists to show: language, appearance, the custom theme, and where the
/// conversation comes from.
struct DemoSettingsView: View {
  @Binding var language: DemoLanguage
  @Binding var appearance: DemoAppearance
  @Binding var customTheme: Bool
  @Binding var preferFixture: Bool
  let hasKey: Bool

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Language", selection: $language) {
            ForEach(DemoLanguage.allCases) { Text($0.label).tag($0) }
          }
          Picker("Appearance", selection: $appearance) {
            ForEach(DemoAppearance.allCases) { Text($0.label).tag($0) }
          }
          Toggle("Custom theme", isOn: $customTheme)
        } header: {
          Text("The chat screen")
        } footer: {
          Text("The custom theme is CnctChatFixture.customTheme: #D7262E, corner radius 8, Georgia and a logo of its own.")
        }

        Section {
          Toggle("Scripted conversation", isOn: hasKey ? $preferFixture : .constant(true))
            .disabled(!hasKey)
        } header: {
          Text("Data")
        } footer: {
          Text(
            hasKey
              ? "Off: your inbox, live. On: the scripted conversation, with no network."
              : "No CNCT_PUBLIC_KEY is set, so the demo plays the scripted conversation with no network. Put a key in Examples/ChatDemo/Local.xcconfig to chat with your inbox."
          )
        }
      }
      .navigationTitle("Settings")
    }
  }
}
