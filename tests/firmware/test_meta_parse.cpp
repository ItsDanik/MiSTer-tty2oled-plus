// Host-side unit tests for the CMDMETA parser in metadisplay.h.
//
// metadisplay.h guards everything that touches the display behind ESP32X /
// HAS_METADISPLAY, so with those undefined the header compiles on a normal
// machine and the parser - the part most likely to be got wrong - can be
// tested without an ESP32, the Arduino toolchain or any hardware.
//
//   g++ -std=c++11 -Wall -Wextra -o test_meta_parse test_meta_parse.cpp && ./test_meta_parse

#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <string>

// --- Minimal Arduino surface used by the parser -----------------------------
static unsigned long g_millis = 1000;
static unsigned long millis() { return g_millis; }

// srcBin is defined by the sketch; the parser only needs the symbol to exist.
uint8_t  g_dummyBuf[16];
uint8_t *srcBin = g_dummyBuf;

// Pulled in with the display code compiled out.
#include "../../MiSTer_SSD1322_USB/metadisplay.h"

// --- Tiny test harness ------------------------------------------------------
static int passed = 0, failed = 0;

static void ok(const char *label, const std::string &got, const std::string &want) {
    if (got == want) {
        passed++;
        printf("  \033[32mok\033[0m   %s\n", label);
    } else {
        failed++;
        printf("  \033[31mFAIL\033[0m %s\n       want: [%s]\n       got:  [%s]\n",
               label, want.c_str(), got.c_str());
    }
}

static void okInt(const char *label, long got, long want) {
    char g[32], w[32];
    snprintf(g, sizeof(g), "%ld", got);
    snprintf(w, sizeof(w), "%ld", want);
    ok(label, g, w);
}

static void section(const char *s) { printf("\n\033[1m%s\033[0m\n", s); }

int main() {

    section("well-formed arcade metadata");
    {
        bool r = meta_parse("CMDMETA,1,12,Donkey Kong (US set 1)|Year=1981|Manufacturer=Nintendo of America|Category=Platform");
        okInt("returns true",  r ? 1 : 0, 1);
        okInt("kind",          metaKind, MKIND_ARCADE);
        okInt("interval",      metaInterval, 12);
        ok   ("title",         metaTitle, "Donkey Kong (US set 1)");
        okInt("field count",   metaFieldCount, 3);
        ok   ("field 0 label", metaFields[0].label, "Year");
        ok   ("field 0 value", metaFields[0].value, "1981");
        ok   ("field 2 label", metaFields[2].label, "Category");
        ok   ("field 2 value", metaFields[2].value, "Platform");
    }

    section("console metadata");
    {
        meta_parse("CMDMETA,2,0,Super Mario World|System=SNES|Region=USA|Year=1990");
        okInt("kind",        metaKind, MKIND_CONSOLE);
        okInt("interval",    metaInterval, 0);
        ok   ("title",       metaTitle, "Super Mario World");
        okInt("field count", metaFieldCount, 3);
    }

    section("title only, no fields");
    {
        meta_parse("CMDMETA,3,0,Amiga");
        okInt("kind",        metaKind, MKIND_COMPUTER);
        ok   ("title",       metaTitle, "Amiga");
        okInt("field count", metaFieldCount, 0);
    }

    section("empty values are dropped");
    {
        meta_parse("CMDMETA,1,5,Game|Year=|Manufacturer=Capcom|Category=");
        okInt("only non-empty kept", metaFieldCount, 1);
        ok   ("kept the right one",  metaFields[0].label, "Manufacturer");
        ok   ("value",               metaFields[0].value, "Capcom");
    }

    section("malformed input is rejected, not crashed on");
    {
        okInt("no commas",        meta_parse("CMDMETA")            ? 1 : 0, 0);
        okInt("one comma",        meta_parse("CMDMETA,1")          ? 1 : 0, 0);
        okInt("two commas",       meta_parse("CMDMETA,1,12")       ? 1 : 0, 0);
        okInt("kind out of range",meta_parse("CMDMETA,9,12,X")     ? 1 : 0, 0);
        okInt("negative kind",    meta_parse("CMDMETA,-1,12,X")    ? 1 : 0, 0);
    }

    section("interval is clamped");
    {
        meta_parse("CMDMETA,1,99999,Game|Year=1981");
        okInt("upper clamp", metaInterval, 600);
        meta_parse("CMDMETA,1,-5,Game|Year=1981");
        okInt("lower clamp", metaInterval, 0);
    }

    section("oversized input is truncated, not overflowed");
    {
        // Title longer than META_MAX_TITLE, value longer than META_MAX_VALUE.
        std::string longTitle(200, 'T');
        std::string longValue(200, 'V');
        std::string cmd = "CMDMETA,1,10," + longTitle + "|Year=" + longValue;

        meta_parse(cmd.c_str());
        okInt("title truncated to cap", (long)strlen(metaTitle), META_MAX_TITLE - 1);
        okInt("title NUL terminated",   metaTitle[META_MAX_TITLE - 1] == 0 ? 1 : 0, 1);
        okInt("value truncated to cap", (long)strlen(metaFields[0].value), META_MAX_VALUE - 1);
    }

    section("more fields than storage");
    {
        meta_parse("CMDMETA,1,10,Game|A=1|B=2|C=3|D=4|E=5|F=6|G=7|H=8|I=9");
        okInt("capped at META_MAX_FIELDS", metaFieldCount, META_MAX_FIELDS);
        ok   ("first kept",  metaFields[0].label, "A");
        ok   ("last kept",   metaFields[META_MAX_FIELDS - 1].label, "F");
    }

    section("segments without '=' are skipped");
    {
        meta_parse("CMDMETA,1,10,Game|junk|Year=1981|more junk|Category=Maze");
        okInt("only pairs kept", metaFieldCount, 2);
        ok   ("first",  metaFields[0].label, "Year");
        ok   ("second", metaFields[1].label, "Category");
    }

    section("values may contain '=' and other punctuation");
    {
        meta_parse("CMDMETA,1,10,Game|Note=a=b=c|Title=Zero Wing: All Your Base");
        ok("split on first '=' only", metaFields[0].value, "a=b=c");
        ok("colons survive",          metaFields[1].value, "Zero Wing: All Your Base");
    }

    section("state resets between games");
    {
        meta_parse("CMDMETA,1,10,First|A=1|B=2|C=3");
        okInt("three fields", metaFieldCount, 3);
        meta_parse("CMDMETA,2,0,Second|A=1");
        okInt("count reset",  metaFieldCount, 1);
        ok   ("title reset",  metaTitle, "Second");
    }

    section("trailing separator");
    {
        meta_parse("CMDMETA,1,10,Game|Year=1981|");
        okInt("no phantom field", metaFieldCount, 1);
    }

    section("empty title is allowed");
    {
        meta_parse("CMDMETA,1,10,|Year=1981");
        ok   ("title empty", metaTitle, "");
        okInt("field read",  metaFieldCount, 1);
    }

    printf("\n\033[1mResults:\033[0m %d passed, %d failed\n\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
