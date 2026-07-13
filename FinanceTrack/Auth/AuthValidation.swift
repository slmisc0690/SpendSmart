import Foundation

/// Pure validation logic for the auth screens — no networking, no Supabase SDK. Kept separate
/// from the views so the rules themselves are unit-testable without a live session.
enum AuthValidation {
    /// Deliberately simple (not a full RFC 5322 parser) — good enough to catch obvious typos
    /// before a network round-trip; Supabase itself is the real source of truth on email validity.
    static func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let atIndex = trimmed.firstIndex(of: "@") else { return false }
        let domain = trimmed[trimmed.index(after: atIndex)...]
        return trimmed.firstIndex(of: "@") == trimmed.lastIndex(of: "@")
            && atIndex != trimmed.startIndex
            && domain.contains(".")
            && !domain.hasPrefix(".")
            && !domain.hasSuffix(".")
            && !trimmed.hasSuffix("@")
    }

    /// Empty when the password is acceptable; otherwise one message per unmet requirement, so the
    /// UI can show all of them at once rather than one-at-a-time.
    static func passwordValidationMessages(_ password: String) -> [String] {
        var messages: [String] = []
        if password.count < 8 {
            messages.append("At least 8 characters")
        }
        if !password.contains(where: \.isNumber) {
            messages.append("At least one number")
        }
        return messages
    }

    static func isPasswordValid(_ password: String) -> Bool {
        passwordValidationMessages(password).isEmpty
    }

    static func passwordsMatch(_ password: String, _ confirmation: String) -> Bool {
        !password.isEmpty && password == confirmation
    }
}
