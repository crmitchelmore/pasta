import SwiftUI

import PastaCore

struct ChromeAlertModifier: ViewModifier {
    @Binding var isShowingErrorAlert: Bool
    let lastError: PastaError?
    let clearError: () -> Void
    let errorMessage: (PastaError) -> String

    func body(content: Content) -> some View {
        content
            .alert(
                lastError?.errorDescription ?? "Error",
                isPresented: $isShowingErrorAlert,
                presenting: lastError
            ) { _ in
                Button("OK", action: clearError)
            } message: { error in
                Text(errorMessage(error))
            }
    }
}
