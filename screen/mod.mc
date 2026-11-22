// screen — cell grid + differential sync (slimmed from jem display).
import "term";
import "style";

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

struct DispCell {
	uint32_t ch;
	TextStyle style;
};

struct Screen {
	DispCell[..] cells;
	bool[..] row_dirty;
	int rows;
	int cols;
};

static Screen g_screen;
static Screen g_prev;
static bool g_screen_dirty;
static bool g_have_style;
static uint16_t g_active_style_bits;

/* UTF-8 helpers (from jem buffer) — decode for paint; encode for edit insert. */

size_t utf8_next_offset(const char[..] data, size_t offset) {
	size_t size = 1;
	if (offset >= len(data)) {
		return offset;
	}
	char c = data[offset];
	if (c < 0x80) {
		size = 1;
	} else if ((c & 0xE0) == 0xC0) {
		size = 2;
	} else if ((c & 0xF0) == 0xE0) {
		size = 3;
	} else if ((c & 0xF8) == 0xF0) {
		size = 4;
	}
	if (offset + size > len(data)) {
		return offset + 1;
	}
	return offset + size;
}

size_t utf8_prev_offset(const char[..] data, size_t offset) {
	if (offset == 0 || len(data) == 0) {
		return 0;
	}
	size_t i = offset - 1;
	if (i >= len(data)) {
		i = len(data) - 1;
	}
	while (i > 0 && (data[i] & 0xC0) == 0x80) {
		i--;
	}
	return i;
}

(uint32_t, size_t) utf8_decode_rune(const char[..] data, size_t offset) {
	size_t n = len(data);
	if (offset >= n) {
		return (0, 0);
	}
	char c = data[offset];
	if (c < 0x80) {
		return (c, 1);
	}
	if ((c & 0xE0) == 0xC0 && offset + 1 < n) {
		uint32_t r = (uint32_t)(c & 0x1F) << 6;
		r |= data[offset + 1] & 0x3F;
		return (r, 2);
	}
	if ((c & 0xF0) == 0xE0 && offset + 2 < n) {
		uint32_t r = (uint32_t)(c & 0x0F) << 12;
		r |= (uint32_t)(data[offset + 1] & 0x3F) << 6;
		r |= data[offset + 2] & 0x3F;
		return (r, 3);
	}
	if ((c & 0xF8) == 0xF0 && offset + 3 < n) {
		uint32_t r = (uint32_t)(c & 0x07) << 18;
		r |= (uint32_t)(data[offset + 1] & 0x3F) << 12;
		r |= (uint32_t)(data[offset + 2] & 0x3F) << 6;
		r |= data[offset + 3] & 0x3F;
		return (r, 4);
	}
	return (c, 1);
}

int rune_display_width(uint32_t r) {
	if (r == 0 || r < 32 || (r >= 0x7F && r < 0xA0)) {
		return 0;
	}
	if (r == (uint32_t)'\t') {
		return 1;
	}
	if (r >= 0x1100 &&
		((r <= 0x115F) || (r >= 0x2E80 && r <= 0xA4CF) ||
			(r >= 0xAC00 && r <= 0xD7A3) ||
			(r >= 0xF900 && r <= 0xFAFF) ||
			(r >= 0xFE10 && r <= 0xFE6F) ||
			(r >= 0xFF00 && r <= 0xFF60) ||
			(r >= 0xFFE0 && r <= 0xFFE6) ||
			(r >= 0x20000 && r <= 0x3FFFD))) {
		return 2;
	}
	return 1;
}

size_t utf8_encode_rune(uint32_t r, char[..] out) {
	if (cap(out) < 4) {
		return 0;
	}
	if ((r >= 0xD800 && r <= 0xDFFF) || r > 0x10FFFF) {
		r = 0xFFFD;
	}
	if (r < 0x80) {
		out[0] = (char)r;
		return 1;
	}
	if (r < 0x800) {
		out[0] = (char)(0xC0 | (r >> 6));
		out[1] = (char)(0x80 | (r & 0x3F));
		return 2;
	}
	if (r < 0x10000) {
		out[0] = (char)(0xE0 | (r >> 12));
		out[1] = (char)(0x80 | ((r >> 6) & 0x3F));
		out[2] = (char)(0x80 | (r & 0x3F));
		return 3;
	}
	out[0] = (char)(0xF0 | (r >> 18));
	out[1] = (char)(0x80 | ((r >> 12) & 0x3F));
	out[2] = (char)(0x80 | ((r >> 6) & 0x3F));
	out[3] = (char)(0x80 | (r & 0x3F));
	return 4;
}

/* Display columns for data[0..byte_end), stopping at incomplete trailing bytes. */
int utf8_prefix_cols(const char[..] data, size_t byte_end) {
	size_t i = 0;
	int cols = 0;
	size_t n = len(data);
	if (byte_end < n) {
		n = byte_end;
	}
	while (i < n) {
		auto (r, sz) = utf8_decode_rune(data, i);
		int w = 0;
		if (sz == 0 || i + sz > n) {
			break;
		}
		w = rune_display_width(r);
		if (w <= 0) {
			w = 1;
		}
		cols += w;
		i += sz;
	}
	return cols;
}

static TextStyle style_default() {
	return text_style_make(TermColorBase0, TermColorBase03, 0);
}

static TextStyle style_resolve(TextStyle style) {
	TextStyle def = style_default();
	TermColor fg = text_style_fg(style);
	TermColor bg = text_style_bg(style);
	uint16_t flags = (uint16_t)(style.bits & ((uint16_t)TextStyleBold | (uint16_t)TextStyleUnderline | (uint16_t)TextStyleReverse));
	if (fg == TermColorDefault) {
		fg = text_style_fg(def);
	}
	if (bg == TermColorDefault) {
		bg = text_style_bg(def);
	}
	return text_style_make(fg, bg, flags);
}

TextStyle screen_style_default() {
	return style_default();
}

TextStyle screen_style_selected() {
	return text_style_make(TermColorBase03, TermColorYellow, 0);
}

TextStyle screen_style_header() {
	return text_style_make(TermColorBase1, TermColorBase02, (uint16_t)TextStyleBold);
}

TextStyle screen_style_status(char letter) {
	/* A:Inbox … G:Someday; Now stays hot; Complete muted vs Someday. */
	TermColor fg = TermColorBase0;
	if (letter == 'A') {
		fg = TermColorBlue;
		/* Inbox — capture, not WIP */
	} else if (letter == 'B') {
		fg = TermColorRed;
		/* Now */
	} else if (letter == 'C') {
		fg = TermColorYellow;
		/* Soon */
	} else if (letter == 'D') {
		fg = TermColorGreen;
		/* Later */
	} else if (letter == 'E') {
		fg = TermColorMagenta;
		/* Waiting */
	} else if (letter == 'F') {
		fg = TermColorBase01;
		/* Complete — quiet */
	} else if (letter == 'G') {
		fg = TermColorCyan;
		/* Someday */
	}
	return text_style_make(fg, TermColorBase03, (uint16_t)TextStyleBold);
}

static void screen_free(Screen* s) {
	release(&s.cells);
	release(&s.row_dirty);
	s.rows = 0;
	s.cols = 0;
}

static bool screen_resize(Screen* s, int rows, int cols) {
	TextStyle def = style_default();
	if (rows < 1) {
		rows = 1;
	}
	if (cols < 1) {
		cols = 1;
	}
	if (s.rows == rows && s.cols == cols && ptr(s.cells) != NULL && ptr(s.row_dirty) != NULL) {
		return true;
	}
	int n = rows * cols;
	DispCell[..] pv = alloc(DispCell, (size_t)n);
	bool[..] dirty = alloc(bool, (size_t)rows);
	if (ptr(pv) == NULL || ptr(dirty) == NULL) {
		release(&pv);
		release(&dirty);
		return false;
	}
	for (auto* cell: pv) {
		cell.ch = ' ';
		cell.style = def;
	}
	for (auto* d: dirty) {
		*d = false;
	}
	release(&s.cells);
	release(&s.row_dirty);
	s.cells = pv;
	s.row_dirty = dirty;
	s.rows = rows;
	s.cols = cols;
	return true;
}

static DispCell* cell_at(Screen* s, int row, int col) {
	if (row < 0 || col < 0 || row >= s.rows || col >= s.cols) {
		return NULL;
	}
	return &s.cells[row * s.cols + col];
}

void screen_put_rune(int row, int col, uint32_t ch, TextStyle style) {
	DispCell* c = cell_at(&g_screen, row, col);
	if (c == NULL) {
		return;
	}
	if (c.ch == ch && text_style_eq(c.style, style)) {
		return;
	}
	c.ch = ch;
	c.style = style;
	if (ptr(g_screen.row_dirty) != NULL && row >= 0 && row < g_screen.rows) {
		g_screen.row_dirty[row] = true;
	}
}

void screen_put_str(int row, int col, const char[..] text, TextStyle style) {
	int c = col;
	size_t i = 0;
	if (ptr(text) == NULL) {
		return;
	}
	while (i < len(text) && c < g_screen.cols) {
		auto (r, sz) = utf8_decode_rune(text, i);
		int w = 0;
		if (sz == 0) {
			break;
		}
		if (r == 0) {
			break;
		}
		w = rune_display_width(r);
		if (w <= 0) {
			w = 1;
		}
		if (c + w > g_screen.cols) {
			break;
		}
		screen_put_rune(row, c, r, style);
		for (int k = 1; k < w; k++) {
			screen_put_rune(row, c + k, 0, style);
		}
		c += w;
		i += sz;
	}
}

void screen_put_cstr(int row, int col, const char* text, TextStyle style) {
	if (text == NULL) {
		return;
	}
	screen_put_str(row, col, ranged(text, strlen(text)), style);
}

void screen_fill_row(int row, TextStyle style) {
	int col = 0;
	for (; col < g_screen.cols; col++) {
		screen_put_rune(row, col, ' ', style);
	}
}

void screen_clear() {
	int row = 0;
	TextStyle def = style_default();
	for (; row < g_screen.rows; row++) {
		screen_fill_row(row, def);
	}
}

/* Solarized / ANSI RGB — match jem truecolor table. */
static const char[..] color_rgb_base[] = {
	"7;54;66", "220;50;47", "133;153;0", "181;137;0", "38;139;210", "211;54;130", "42;161;152", "238;232;213", };

static const char[..] color_rgb_sol[] = {
	"0;43;54", "7;54;66", "88;110;117", "101;123;131", "131;148;150", "147;161;161", "238;232;213", "253;246;227", };

static const char[..] color_rgb(TermColor c) {
	int i = c;
	if (i >= 0 && i <= 7) {
		return color_rgb_base[i];
	}
	if (i >= 17 && i <= 24) {
		return color_rgb_sol[i - 17];
	}
	return "";
}

static int append_color_sgr(char* buf, size_t cap, int n, TermColor c, int base_sgr) {
	int i = c;
	if (c == TermColorDefault || n < 0) {
		return n;
	}
	if ((size_t)n >= cap) {
		return -1;
	}
	if (i >= 8 && i < 16) {
		int wn = snprintf(buf + n, cap - (size_t)n, ";%d", base_sgr + 60 + (i - 8));
		if (wn < 0 || (size_t)wn >= cap - (size_t)n) {
			return -1;
		}
		return n + wn;
	}
	const char[..] rgb = color_rgb(c);
	if (len(rgb) == 0) {
		return n;
	}
	int wn = snprintf(buf + n, cap - (size_t)n, ";%d;2;%s", base_sgr + 8, rgb);
	if (wn < 0 || (size_t)wn >= cap - (size_t)n) {
		return -1;
	}
	return n + wn;
}

static void emit_sgr(TextStyle style) {
	char seq[96] = { 0 };
	TextStyle resolved = style_resolve(style);
	TermColor fg = text_style_fg(resolved);
	TermColor bg = text_style_bg(resolved);
	if (resolved.bits & (uint16_t)TextStyleReverse) {
		TermColor tmp = fg;
		fg = bg;
		bg = tmp;
	}
	int n = snprintf(seq, sizeof(seq), "\x1b[0%s%s%s", (resolved.bits & (uint16_t)TextStyleBold) ? ";1": "", (resolved.bits & (uint16_t)TextStyleUnderline) ? ";4": "", (resolved.bits & (uint16_t)TextStyleReverse) ? ";7": "");
	if (n < 0 || (size_t)n >= sizeof(seq)) {
		return;
	}
	n = append_color_sgr(seq, sizeof(seq), n, fg, 30);
	n = append_color_sgr(seq, sizeof(seq), n, bg, 40);
	if (n < 0 || (size_t)n + 1 >= sizeof(seq)) {
		return;
	}
	seq[n++] = 'm';
	seq[n] = 0;
	term_write(seq, n);
}

static void emit_sgr_cached(TextStyle style) {
	if (g_have_style && g_active_style_bits == style.bits) {
		return;
	}
	emit_sgr(style);
	g_active_style_bits = style.bits;
	g_have_style = true;
}

static void screen_write_span(int row, int from, int to) {
	char out[4096] = { 0 };
	int out_len = 0;
	int i = from;
	for (; i < to; i++) {
		DispCell* c = cell_at(&g_screen, row, i);
		uint32_t ch = 0;
		char tmp[4] = { 0 };
		int sz = 0;
		if (c == NULL || c.ch == 0) {
			continue;
		}
		ch = c.ch;
		if (ch < 128) {
			tmp[0] = (char)ch;
			sz = 1;
		} else if (ch < 0x800) {
			tmp[0] = (char)(0xC0 | (ch >> 6));
			tmp[1] = (char)(0x80 | (ch & 0x3F));
			sz = 2;
		} else if (ch < 0x10000) {
			tmp[0] = (char)(0xE0 | (ch >> 12));
			tmp[1] = (char)(0x80 | ((ch >> 6)& 0x3F));
			tmp[2] = (char)(0x80 | (ch & 0x3F));
			sz = 3;
		} else {
			tmp[0] = (char)(0xF0 | (ch >> 18));
			tmp[1] = (char)(0x80 | ((ch >> 12)& 0x3F));
			tmp[2] = (char)(0x80 | ((ch >> 6)& 0x3F));
			tmp[3] = (char)(0x80 | (ch & 0x3F));
			sz = 4;
		}
		if (out_len + sz > (int) sizeof(out)) {
			term_write(out, out_len);
			out_len = 0;
		}
		memcpy(out + out_len, tmp, sz);
		out_len += sz;
	}
	if (out_len > 0) {
		term_write(out, out_len);
	}
}

static void copy_front_cell(int row, int col) {
	DispCell* a = cell_at(&g_screen, row, col);
	DispCell* b = cell_at(&g_prev, row, col);
	if (a == NULL || b == NULL) {
		return;
	}
	*b = *a;
}

static void row_emit_diffs(int row, int from, int to) {
	int k = from;
	int cols = g_screen.cols;
	if (to > cols) {
		to = cols;
	}
	while (k < to) {
		DispCell* a = { 0 };
		DispCell* b = { 0 };
		while (k < to) {
			a = cell_at(&g_screen, row, k);
			b = cell_at(&g_prev, row, k);
			if (a == NULL || b == NULL) {
				break;
			}
			if (a.ch != b.ch || !text_style_eq(a.style, b.style)) {
				break;
			}
			k++;
		}
		if (k >= to) {
			break;
		}
		term_move(row, k);
		while (k < to) {
			TextStyle style = { 0 };
			int run = 0;
			a = cell_at(&g_screen, row, k);
			b = cell_at(&g_prev, row, k);
			if (a == NULL || b == NULL) {
				break;
			}
			if (a.ch == b.ch && text_style_eq(a.style, b.style)) {
				break;
			}
			style = a.style;
			emit_sgr_cached(style);
			run = k;
			while (run < to) {
				DispCell* ra = cell_at(&g_screen, row, run);
				DispCell* rb = cell_at(&g_prev, row, run);
				if (ra == NULL || rb == NULL) {
					break;
				}
				if (!text_style_eq(ra.style, style)) {
					break;
				}
				if (ra.ch == rb.ch && text_style_eq(ra.style, rb.style)) {
					break;
				}
				run++;
			}
			screen_write_span(row, k, run);
			while (k < run) {
				copy_front_cell(row, k);
				k++;
			}
		}
	}
}

static void row_sync(int row) {
	int cols = g_screen.cols;
	int first = 0;
	TextStyle normal = style_default();
	if (row < 0 || row >= g_screen.rows || cols <= 0) {
		return;
	}
	while (first < cols) {
		DispCell* a = cell_at(&g_screen, row, first);
		DispCell* b = cell_at(&g_prev, row, first);
		if (a == NULL || b == NULL || a.ch != b.ch || !text_style_eq(a.style, b.style)) {
			break;
		}
		first++;
	}
	if (first == cols) {
		return;
	}
	int last = cols - 1;
	while (last > first) {
		DispCell* a = cell_at(&g_screen, row, last);
		DispCell* b = cell_at(&g_prev, row, last);
		if (a == NULL || b == NULL || a.ch != b.ch || !text_style_eq(a.style, b.style)) {
			break;
		}
		last--;
	}
	int lastsp = cols;
	while (lastsp > first) {
		DispCell* a = cell_at(&g_screen, row, lastsp - 1);
		if (a == NULL || a.ch != (uint32_t)' ' || !text_style_eq(a.style, normal)) {
			break;
		}
		lastsp--;
	}
	if (lastsp <= last) {
		int i = lastsp;
		row_emit_diffs(row, first, lastsp);
		term_move(row, lastsp);
		emit_sgr_cached(normal);
		term_erase_eol();
		for (; i < cols; i++) {
			DispCell* b = cell_at(&g_prev, row, i);
			if (b != NULL) {
				b.ch = ' ';
				b.style = normal;
			}
		}
	} else {
		row_emit_diffs(row, first, last + 1);
	}
}

static void mark_all_dirty() {
	int i = 0;
	if (ptr(g_screen.row_dirty) == NULL) {
		return;
	}
	for (; i < g_screen.rows; i++) {
		g_screen.row_dirty[i] = true;
	}
}

static void reset_front_to_spaces() {
	int i = 0;
	TextStyle normal = style_default();
	if (ptr(g_prev.cells) == NULL) {
		return;
	}
	int n = g_prev.rows * g_prev.cols;
	for (; i < n; i++) {
		g_prev.cells[i].ch = ' ';
		g_prev.cells[i].style = normal;
	}
}

static void screen_sync() {
	int i = 0;
	if (g_screen_dirty) {
		TextStyle normal = style_default();
		mark_all_dirty();
		reset_front_to_spaces();
		term_move(0, 0);
		emit_sgr_cached(normal);
		term_erase_eos();
		g_have_style = false;
		g_screen_dirty = false;
	}
	for (; i < g_screen.rows; i++) {
		if (ptr(g_screen.row_dirty) != NULL && g_screen.row_dirty[i]) {
			g_screen.row_dirty[i] = false;
			row_sync(i);
		}
	}
}

void screen_init() {
	g_screen_dirty = true;
	g_have_style = false;
	screen_resize(&g_screen, term_rows(), term_cols());
	screen_resize(&g_prev, term_rows(), term_cols());
}

void screen_shutdown() {
	screen_free(&g_screen);
	screen_free(&g_prev);
}

void screen_invalidate() {
	g_screen_dirty = true;
}

bool screen_ensure_size() {
	int rows = term_rows();
	int cols = term_cols();
	if (rows < 1) {
		rows = 1;
	}
	if (cols < 1) {
		cols = 1;
	}
	if (g_screen.rows == rows && g_screen.cols == cols) {
		return true;
	}
	if (!screen_resize(&g_screen, rows, cols) || !screen_resize(&g_prev, rows, cols)) {
		return false;
	}
	g_screen_dirty = true;
	g_have_style = false;
	return true;
}

int screen_rows() {
	return g_screen.rows;
}

int screen_cols() {
	return g_screen.cols;
}

void screen_present(int cursor_row, int cursor_col) {
	screen_sync();
	term_move(cursor_row, cursor_col);
	term_flush();
}
