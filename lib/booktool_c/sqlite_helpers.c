// Tiny C-side helpers for sqlite3 calls that translate-c can't express
// cleanly in Zig. Linked statically into the booktool binary.

#include <sqlite3.h>
#include <stddef.h>

// Bind a TEXT value with SQLITE_TRANSIENT semantics (SQLite copies the
// bytes; caller may free them immediately). The SQLITE_TRANSIENT macro
// is a function-pointer sentinel value of `-1` that Zig won't accept
// because the literal address is not function-aligned.
int booktool_bind_text(sqlite3_stmt *stmt, int idx, const char *text, int len) {
    return sqlite3_bind_text(stmt, idx, text, len, SQLITE_TRANSIENT);
}
