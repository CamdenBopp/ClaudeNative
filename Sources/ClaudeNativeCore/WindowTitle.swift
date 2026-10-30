/// What a conversation window is called. Named by its conversation, as
/// Mail and Messages name theirs: every window used to be "Claude", so two
/// windows on one folder read the same in the Window menu and VoiceOver's
/// window list.
public enum WindowTitle {
    public static func forConversation(_ title: String?) -> String {
        guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return "New Session" }
        return title
    }
}
