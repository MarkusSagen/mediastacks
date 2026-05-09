// Aggregated C headers translated by build.zig via b.addTranslateC.
// Source files import these via the "c" module.

#ifndef BOOKTOOL_C_INCLUDES_H
#define BOOKTOOL_C_INCLUDES_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

// NOTE: miniz is intentionally NOT translated here — translate-c crashes
// on its zlib-compat header. miniz.zig declares just the few symbols we
// need as `extern "c"` directly.

// libmobi — MOBI/AZW3 reading, metadata, cover, MOBI->EPUB conversion.
#include <mobi.h>

// libxml2 — OPF and XHTML parsing for EPUB.
#include <libxml/parser.h>
#include <libxml/tree.h>
#include <libxml/xpath.h>
#include <libxml/xpathInternals.h>

// sqlite3 — local catalog.
#include <sqlite3.h>

#endif
