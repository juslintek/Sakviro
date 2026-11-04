import SwiftUI

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 80, height: 80)
            Text("Meet \(MeetingActions.appName)")
                .font(.appLargeTitle)
                .fontWeight(.bold)
            Text("Records your calls, writes everything down,\nand helps you live while you talk.")
                .font(Theme.Typography.sans(14))
                .foregroundStyle(Theme.Colors.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Spacer()
        }
        .padding(Theme.Metrics.pad)
    }
}
