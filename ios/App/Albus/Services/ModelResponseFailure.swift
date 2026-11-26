/// Copy for the one retryable model-output failure shared by planning,
/// marking, and Ask Albus.
///
/// The server distinguishes an empty answer from malformed structured output
/// for logging and diagnosis. A student cannot act on that distinction: in
/// either case Claude returned nothing Albus could safely use, and a fresh
/// request will usually succeed.
enum ModelResponseFailure {
    static let retryableDescription = "Albus got an answer back that it couldn't use. Try again."
}
