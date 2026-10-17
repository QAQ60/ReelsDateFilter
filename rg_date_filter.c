#include "rg_date_filter.h"

#include <ctype.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* 把全角负号/句点/加号转成半角，便于统一解析 */
static char *rg_normalize(const char *input)
{
    size_t len = strlen(input);
    char *buf = (char *)malloc(len + 1);
    if (!buf) return NULL;

    size_t j = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)input[i];
        if (c == 0xEF && i + 2 < len) {
            /* UTF-8 全角符号：EF BC 8D '－'，EF BC 8E '．'，EF BC 8B '＋' */
            unsigned char c2 = (unsigned char)input[i + 1];
            unsigned char c3 = (unsigned char)input[i + 2];
            if (c2 == 0xBC && c3 == 0x8D) { buf[j++] = '-'; i += 2; continue; }
            if (c2 == 0xBC && c3 == 0x8E) { buf[j++] = '.'; i += 2; continue; }
            if (c2 == 0xBC && c3 == 0x8B) { buf[j++] = '+'; i += 2; continue; }
        }
        buf[j++] = (char)c;
    }
    buf[j] = '\0';
    return buf;
}

RGParseResult rg_parse_days(const char *input, double *out, RGDateFilter *filter)
{
    if (!input) return RGParseInvalid;

    /* 去掉首尾空白 */
    while (*input && isspace((unsigned char)*input)) input++;
    size_t len = strlen(input);
    while (len > 0 && isspace((unsigned char)input[len - 1])) len--;
    if (len == 0) {
        if (filter) *filter = rg_filter_make(0);
        if (out) *out = 0;
        return RGParseEmpty;
    }

    char *raw = (char *)malloc(len + 1);
    if (!raw) return RGParseInvalid;
    memcpy(raw, input, len);
    raw[len] = '\0';

    char *norm = rg_normalize(raw);
    free(raw);
    if (!norm) return RGParseInvalid;

    /* 只允许 [+-]?digits[.digits]，至少一位数字 */
    size_t i = 0, digits = 0, dots = 0;
    if (norm[i] == '+' || norm[i] == '-') i++;
    for (; norm[i]; i++) {
        if (isdigit((unsigned char)norm[i])) { digits++; continue; }
        if (norm[i] == '.' && dots == 0) { dots++; continue; }
        free(norm);
        return RGParseInvalid;
    }
    if (digits == 0) { free(norm); return RGParseInvalid; }

    char *end = NULL;
    double value = strtod(norm, &end);
    int consumed_all = (end && *end == '\0');
    free(norm);

    if (!consumed_all || isnan(value) || isinf(value)) return RGParseInvalid;
    if (fabs(value) > RG_FILTER_MAX_DAYS) return RGParseTooLarge;

    if (out) *out = value;

    if (value != 0 && fabs(value) < RG_FILTER_MIN_DAYS) {
        if (filter) *filter = rg_filter_make(0);
        return RGParseTooSmall;
    }

    if (filter) *filter = rg_filter_make(value);
    if (value == 0) return RGParseZero;
    return RGParseOK;
}

RGDateFilter rg_filter_make(double days)
{
    RGDateFilter f;
    if (days == 0 || isnan(days) || isinf(days)) {
        f.mode = RGDateFilterOff;
        f.days = 0;
        return f;
    }
    f.mode = (days > 0) ? RGDateFilterNewer : RGDateFilterOlder;
    f.days = fabs(days);
    return f;
}

int rg_filter_should_keep(RGDateFilter filter, double age_seconds)
{
    if (filter.mode == RGDateFilterOff) return 1;
    if (age_seconds < 0) age_seconds = 0;   /* 设备时间回拨，按刚发布处理 */

    double limit = filter.days * RG_SECONDS_PER_DAY;
    if (filter.mode == RGDateFilterNewer) return age_seconds <= limit;
    return age_seconds > limit;
}

int rg_should_stop_pagination(RGDateFilter filter, size_t page_count, size_t kept_count)
{
    if (filter.mode == RGDateFilterOff) return 0;
    if (page_count == 0) return 1;      /* 没有更多数据 */
    return kept_count == 0;             /* 整页都被过滤，继续翻页没有意义 */
}
