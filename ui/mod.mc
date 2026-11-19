// ui — planner paint: filters, table, notes, footer.
import "model";
import "screen";
import "style";
import "term";
import "str";

#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
	UiColHeaderRow = 0,
	UiFooterRows = 1,
	UiNotesMin = 3
};

struct UiState {
	TaskStore *store;
	ViewFilter *filter;
	int[..] visible;
	int visible_count;
	int selected; /* index into visible[] */
	int scroll;
	char mode_line[160];
	char prompt[80];
	char input[TaskNotesCap];
	int input_len;
	int input_cursor; /* caret within input[0..input_len] */
	bool editing;
};

void ui_init(UiState *ui, TaskStore *store, ViewFilter *filter, int[..] visible) {
	if (ui == NULL) {
		return;
	}
	memset(ui, 0, sizeof(*ui));
	ui.store = store;
	ui.filter = filter;
	ui.visible = visible;
	ui.selected = 0;
	ui.scroll = 0;
	snprintf(ui.mode_line, sizeof(ui.mode_line), "q2");
}

void ui_set_status(UiState *ui, const char *msg) {
	if (ui == NULL) {
		return;
	}
	snprintf(ui.mode_line, sizeof(ui.mode_line), "%s", msg != NULL ? msg : "");
}

static void put_clipped(int row, int col, int width, const char *text, TextStyle st) {
	int i = 0;
	if (width <= 0) {
		return;
	}
	if (text == NULL) {
		text = "";
	}
	const char[..] view = ranged(text, strlen(text));
	for (; i < width; i++) {
		char ch = ' ';
		if (i < (int)len(view)) {
			ch = view[i];
		}
		screen_put_rune(row, col + i, ch, st);
	}
}

/* WordPerfect-style: paint label with mnemonic letter in red+bold (same bg). */
static void put_mnemonic(int row, int col, int width, const char *text, char mnemonic, TextStyle st) {
	int marked = -1;
	char want = mnemonic;
	TextStyle hot = text_style_make(TermColorRed, text_style_bg(st), (uint16_t)TextStyleBold);
	if (width <= 0) {
		return;
	}
	if (text == NULL) {
		text = "";
	}
	if (want >= 'A' && want <= 'Z') {
		want = (char)(want - 'A' + 'a');
	}
	const char[..] view = ranged(text, strlen(text));
	for (int i = 0; i < (int)len(view); i++) {
		char ch = view[i];
		char low = ch;
		if (low >= 'A' && low <= 'Z') {
			low = (char)(low - 'A' + 'a');
		}
		if (low == want) {
			marked = i;
			break;
		}
	}
	for (int i = 0; i < width; i++) {
		char ch = ' ';
		TextStyle use = st;
		if (i < (int)len(view)) {
			ch = view[i];
			if (i == marked) {
				use = hot;
			}
		}
		screen_put_rune(row, col + i, ch, use);
	}
}

static int table_top() {
	return UiColHeaderRow + 1;
}

static int notes_height(int rows) {
	int h = rows / 5;
	if (h < UiNotesMin) {
		h = UiNotesMin;
	}
	if (h > 8) {
		h = 8;
	}
	return h;
}

static int table_height(int rows) {
	int notes = notes_height(rows);
	int h = rows - table_top() - notes - UiFooterRows;
	if (h < 3) {
		h = 3;
	}
	return h;
}

int ui_page_rows() {
	return table_height(screen_rows());
}

void ui_clamp(UiState *ui) {
	if (ui == NULL) {
		return;
	}
	if (ui.visible_count <= 0) {
		ui.selected = 0;
		ui.scroll = 0;
		return;
	}
	if (ui.selected < 0) {
		ui.selected = 0;
	}
	if (ui.selected >= ui.visible_count) {
		ui.selected = ui.visible_count - 1;
	}
	int th = table_height(screen_rows());
	if (ui.selected < ui.scroll) {
		ui.scroll = ui.selected;
	}
	if (ui.selected >= ui.scroll + th) {
		ui.scroll = ui.selected - th + 1;
	}
	if (ui.scroll < 0) {
		ui.scroll = 0;
	}
}

Task *ui_selected_task(UiState *ui) {
	if (ui == NULL || ui.store == NULL || ptr(ui.visible) == NULL) {
		return NULL;
	}
	if (ui.visible_count <= 0 || ui.selected < 0 || ui.selected >= ui.visible_count) {
		return NULL;
	}
	int idx = ui.visible[ui.selected];
	return model_get(ui.store, idx);
}

int ui_selected_store_index(UiState *ui) {
	if (ui == NULL || ptr(ui.visible) == NULL) {
		return -1;
	}
	if (ui.visible_count <= 0 || ui.selected < 0 || ui.selected >= ui.visible_count) {
		return -1;
	}
	return ui.visible[ui.selected];
}

static void col_widths(int cols, int *w_status, int *w_cat, int *w_task, int *w_due, int *w_cc) {
	int status = 18;
	int cat = 14;
	int due = 10;
	int cc = 18;
	int gaps = 4;
	int task = cols - status - cat - due - cc - gaps;
	if (task < 16) {
		cc = 12;
		task = cols - status - cat - due - cc - gaps;
	}
	if (task < 16) {
		due = 0;
		task = cols - status - cat - due - cc - (due > 0 ? gaps : gaps - 1);
	}
	if (task < 12) {
		task = 12;
	}
	*w_status = status;
	*w_cat = cat;
	*w_task = task;
	*w_due = due;
	*w_cc = cc;
}

static void paint_col_header(int cols) {
	TextStyle st = screen_style_header();
	int w_status = 0;
	int w_cat = 0;
	int w_task = 0;
	int w_due = 0;
	int w_cc = 0;
	int c = 0;
	col_widths(cols, &w_status, &w_cat, &w_task, &w_due, &w_cc);
	screen_fill_row(UiColHeaderRow, st);
	put_mnemonic(UiColHeaderRow, c, w_status, "Status", 's', st);
	c += w_status + 1;
	put_mnemonic(UiColHeaderRow, c, w_cat, "Category", 'c', st);
	c += w_cat + 1;
	put_mnemonic(UiColHeaderRow, c, w_task, "Task", 't', st);
	c += w_task + 1;
	if (w_due > 0) {
		put_mnemonic(UiColHeaderRow, c, w_due, "Due", 'd', st);
		c += w_due + 1;
	}
	/* Attn ↔ key a (CC field); first letter matches binding. */
	put_mnemonic(UiColHeaderRow, c, w_cc, "Attn", 'a', st);
}

static void paint_table(UiState *ui, int cols) {
	int top = table_top();
	int th = table_height(screen_rows());
	int row = 0;
	int w_status = 0;
	int w_cat = 0;
	int w_task = 0;
	int w_due = 0;
	int w_cc = 0;
	TextStyle def = screen_style_default();
	col_widths(cols, &w_status, &w_cat, &w_task, &w_due, &w_cc);
	for (; row < th; row++) {
		int vi = ui.scroll + row;
		int screen_row = top + row;
		TextStyle st = def;
		Task *t = NULL;
		int c = 0;
		char letter = ' ';
		screen_fill_row(screen_row, def);
		if (vi < 0 || vi >= ui.visible_count) {
			continue;
		}
		t = model_get(ui.store, ui.visible[vi]);
		if (t == NULL) {
			continue;
		}
		if (vi == ui.selected) {
			st = screen_style_selected();
			screen_fill_row(screen_row, st);
		}
		if (t.status[0] != 0) {
			letter = t.status[0];
		}
		{
			TextStyle sst = vi == ui.selected ? st : screen_style_status(letter);
			put_clipped(screen_row, c, w_status, t.status, sst);
		}
		c += w_status + 1;
		put_clipped(screen_row, c, w_cat, t.category, st);
		c += w_cat + 1;
		put_clipped(screen_row, c, w_task, t.title, st);
		c += w_task + 1;
		if (w_due > 0) {
			put_clipped(screen_row, c, w_due, t.due, st);
			c += w_due + 1;
		}
		put_clipped(screen_row, c, w_cc, t.cc, st);
	}
}

static void paint_notes(UiState *ui, int cols) {
	int rows = screen_rows();
	int nh = notes_height(rows);
	int top = table_top() + table_height(rows);
	TextStyle hdr = screen_style_header();
	TextStyle def = screen_style_default();
	Task *t = ui_selected_task(ui);
	char rest[512] = {0};
	int label_cols = 8; /* "Writeup" */
	screen_fill_row(top, hdr);
	/* Writeup ↔ key w */
	put_mnemonic(top, 1, label_cols, "Writeup", 'w', hdr);
	if (t != NULL) {
		snprintf(rest, sizeof(rest), " | Attn: %s", strlen(t.cc) ? t.cc : "-");
	} else {
		snprintf(rest, sizeof(rest), "%s", "");
	}
	put_clipped(top, 1 + label_cols, cols - (1 + label_cols), rest, hdr);
	for (int i = 1; i < nh; i++) {
		int screen_row = top + i;
		int off = (i - 1) * (cols > 2 ? cols - 2 : 1);
		screen_fill_row(screen_row, def);
		if (t == NULL || strlen(t.notes) == 0) {
			continue;
		}
		const char[..] notes = ranged(t.notes, strlen(t.notes));
		if (off >= (int)len(notes)) {
			continue;
		}
		put_clipped(screen_row, 1, cols - 2, ptr(notes) + off, def);
	}
}

static void paint_footer(UiState *ui, int cols) {
	int row = screen_rows() - 1;
	TextStyle st = screen_style_header();
	char line[512] = {0};
	char summary[240] = {0};
	int total = ui.store != NULL ? ui.store.count : 0;
	screen_fill_row(row, st);
	if (ui.editing) {
		snprintf(line, sizeof(line), " %s%s", ui.prompt, ui.input);
		put_clipped(row, 0, cols, line, st);
		return;
	}
	int n = snprintf(summary, sizeof(summary), "%d/%d", ui.visible_count, total);
	if (n < 0) {
		n = 0;
	}
	if (ui.filter != NULL) {
		if (strlen(ui.filter.cc) != 0 && n < (int)sizeof(summary)) {
			n += snprintf(summary + n, sizeof(summary) - (size_t)n, " @%s", ui.filter.cc);
		}
		if (ui.filter.show_complete && n < (int)sizeof(summary)) {
			n += snprintf(summary + n, sizeof(summary) - (size_t)n, " +C");
		}
		if (strlen(ui.filter.text) != 0 && n < (int)sizeof(summary)) {
			n += snprintf(summary + n, sizeof(summary) - (size_t)n, " /%s", ui.filter.text);
		}
	}
	if (strlen(ui.mode_line) != 0 && n < (int)sizeof(summary)) {
		n += snprintf(summary + n, sizeof(summary) - (size_t)n, " %s", ui.mode_line);
	}
	(void)n;
	snprintf(line, sizeof(line),
		" %s | x/X complete  (n)ew  s(o)rt  (f)ocus  (/)find  (q)uit",
		summary);
	put_clipped(row, 0, cols, line, st);
}

void ui_paint(UiState *ui) {
	if (ui == NULL) {
		return;
	}
	screen_ensure_size();
	int cols = screen_cols();
	ui_clamp(ui);
	/* Overwrite cells only — do not clear. put_rune + screen_sync emit diffs
	 * (jem display lesson); a full clear dirties every row each frame. */
	paint_col_header(cols);
	paint_table(ui, cols);
	paint_notes(ui, cols);
	paint_footer(ui, cols);
	if (ui.editing) {
		int cursor_row = screen_rows() - 1;
		int cursor_col = (int)strlen(ui.prompt) + ui.input_cursor + 1;
		if (cursor_col >= cols) {
			cursor_col = cols - 1;
		}
		if (cursor_col < 0) {
			cursor_col = 0;
		}
		screen_present(cursor_row, cursor_col);
	} else {
		int cursor_row = table_top() + (ui.selected - ui.scroll);
		screen_present(cursor_row, 0);
	}
}

void ui_begin_edit(UiState *ui, const char *prompt, const char *initial) {
	if (ui == NULL) {
		return;
	}
	ui.editing = true;
	snprintf(ui.prompt, sizeof(ui.prompt), "%s", prompt != NULL ? prompt : "");
	snprintf(ui.input, sizeof(ui.input), "%s", initial != NULL ? initial : "");
	ui.input_len = (int)strlen(ui.input);
	ui.input_cursor = ui.input_len;
}

void ui_end_edit(UiState *ui) {
	if (ui == NULL) {
		return;
	}
	ui.editing = false;
	ui.prompt[0] = 0;
	ui.input[0] = 0;
	ui.input_len = 0;
	ui.input_cursor = 0;
}

static void edit_clamp_cursor(UiState *ui) {
	if (ui.input_cursor < 0) {
		ui.input_cursor = 0;
	}
	if (ui.input_cursor > ui.input_len) {
		ui.input_cursor = ui.input_len;
	}
}

static bool key_is_ctl(uint32_t key, char letter) {
	uint32_t want = (uint32_t)TermCTL | (uint32_t)letter;
	if (key == want) {
		return true;
	}
	/* Raw C0 controls: C-a = 0x01 … C-z = 0x1A */
	if (letter >= 'A' && letter <= 'Z' && key == (uint32_t)(letter - '@')) {
		return true;
	}
	if (letter >= 'a' && letter <= 'z' && key == (uint32_t)(letter - 'a' + 1)) {
		return true;
	}
	return false;
}

bool ui_edit_handle_key(UiState *ui, uint32_t key) {
	if (ui == NULL || !ui.editing) {
		return false;
	}
	if (key == (uint32_t)TermKeyEnter || key == '\r' || key == '\n' ||
		key_is_ctl(key, 'M') || key_is_ctl(key, 'J')) {
		return true; /* finished */
	}
	if (key == 0x1B || key_is_ctl(key, 'G')) { /* escape / C-g cancel */
		ui.input[0] = 0;
		ui.input_len = 0;
		ui.input_cursor = 0;
		return true;
	}
	/* Motion — jem/emacs style */
	if (key == (uint32_t)TermKeyLeft || key_is_ctl(key, 'B')) {
		if (ui.input_cursor > 0) {
			ui.input_cursor--;
		}
		return false;
	}
	if (key == (uint32_t)TermKeyRight || key_is_ctl(key, 'F')) {
		if (ui.input_cursor < ui.input_len) {
			ui.input_cursor++;
		}
		return false;
	}
	if (key == (uint32_t)TermKeyHome || key_is_ctl(key, 'A')) {
		ui.input_cursor = 0;
		return false;
	}
	if (key == (uint32_t)TermKeyEnd || key_is_ctl(key, 'E')) {
		ui.input_cursor = ui.input_len;
		return false;
	}
	/* Deletion */
	if (key == 127 || key == 8 || key_is_ctl(key, 'H')) { /* backspace */
		if (ui.input_cursor > 0) {
			int i = ui.input_cursor - 1;
			size_t n = ui.input_len - i;
			memmove(ui.input + i, ui.input + i + 1, n);
			ui.input_len--;
			ui.input_cursor--;
			ui.input[ui.input_len] = 0;
		}
		return false;
	}
	if (key == (uint32_t)TermKeyDelete || key_is_ctl(key, 'D')) {
		if (ui.input_cursor < ui.input_len) {
			int i = ui.input_cursor;
			size_t n = ui.input_len - i;
			memmove(ui.input + i, ui.input + i + 1, n);
			ui.input_len--;
			ui.input[ui.input_len] = 0;
		}
		return false;
	}
	if (key_is_ctl(key, 'K')) { /* kill to end of line */
		ui.input[ui.input_cursor] = 0;
		ui.input_len = ui.input_cursor;
		return false;
	}
	if (key_is_ctl(key, 'U')) { /* kill whole line */
		ui.input[0] = 0;
		ui.input_len = 0;
		ui.input_cursor = 0;
		return false;
	}
	/* Insert printable at caret */
	if (key >= 32 && key < 127) {
		if (ui.input_len + 1 < (int)sizeof(ui.input)) {
			int i = ui.input_cursor;
			size_t n = ui.input_len - i + 1;
			memmove(ui.input + i + 1, ui.input + i, n);
			ui.input[i] = (char)key;
			ui.input_len++;
			ui.input_cursor++;
			edit_clamp_cursor(ui);
		}
		return false;
	}
	return false;
}
