// app — event loop, keybindings, edit modes.
import "event";
import "term";
import "screen";
import "model";
import "store";
import "ui";
import "crash";
import "str";
import "os";
import "fs";

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum AppEditKind {
	EditNone = 0,
	EditTitle = 1,
	EditCc = 2,
	EditFilterText = 3,
	EditNewAttn = 4,
	EditNewTitle = 5,
	EditFilterCc = 6,
	EditKillConfirm = 7
};

struct App {
	TaskStore store;
	ViewFilter filter;
	int visible[VisibleMax];
	int visible_count;
	UiState ui;
	char db_path[1024];
	char new_attn[TaskCcCap]; /* stashed between new-task Attn → title prompts */
	AppEditKind edit_kind;
	int kill_idx; /* store index pending EditKillConfirm */
	bool running;
	bool import_only;
	int64_t db_mtime_ns;
	bool db_mtime_ok;
};

static App g_app;

static char[..] db_path_view() {
	return ranged(g_app.db_path, strlen(g_app.db_path));
}

static void note_db_mtime() {
	auto (info, ok) = fs_stat(db_path_view());
	g_app.db_mtime_ok = ok;
	g_app.db_mtime_ns = ok ? info.mtime_ns : 0;
}

static void refresh_visible() {
	g_app.visible_count = g_app.store.build_visible(&g_app.filter,
		ranged(g_app.visible, VisibleMax));
	g_app.ui.visible_count = g_app.visible_count;
	ui_clamp(&g_app.ui);
}

static void select_task_id(const char[..] id) {
	int i = 0;
	if (len(id) == 0) {
		return;
	}
	for (; i < g_app.visible_count; i++) {
		Task *t = g_app.store.get(g_app.visible[i]);
		if (t != NULL && str_eq(t.id, id)) {
			g_app.ui.selected = i;
			ui_clamp(&g_app.ui);
			return;
		}
	}
}

static void capture_id(char[..] dst, const Task *t) {
	cstr_reset(dst);
	if (t != NULL) {
		(void)cstr_write(dst, t.id);
	}
}

static void mark_saved() {
	ui_set_status(&g_app.ui, "saved");
}

/* Persist without clobbering a status flash message. */
static bool save_db_quiet() {
	if (!g_app.store.save(db_path_view())) {
		ui_set_status(&g_app.ui, "save failed");
		return false;
	}
	note_db_mtime();
	return true;
}

static bool save_db() {
	if (!save_db_quiet()) {
		return false;
	}
	mark_saved();
	return true;
}

static TaskStore g_incoming;

/* When the DB file changes, merge by id + updated (task-level LWW). */
static bool maybe_reload_db() {
	char id[TaskIdCap] = {0};
	if (g_app.ui.editing) {
		return false;
	}
	auto (info, ok) = fs_stat(db_path_view());
	if (!ok) {
		return false;
	}
	if (g_app.db_mtime_ok && info.mtime_ns == g_app.db_mtime_ns) {
		return false;
	}
	capture_id(ranged(id, sizeof(id)), ui_selected_task(&g_app.ui));
	if (!g_incoming.load(db_path_view())) {
		/* Keep last-good mtime so a partial Syncthing write is retried. */
		ui_set_status(&g_app.ui, "reload failed");
		return true;
	}
	bool changed = g_app.store.merge(&g_incoming);
	note_db_mtime();
	if (changed) {
		(void)save_db_quiet();
		ui_set_status(&g_app.ui, "merged");
	}
	refresh_visible();
	select_task_id(ranged(id, cstr_zlen(ranged(id, sizeof(id)))));
	return true;
}

static void crash_cleanup() {
	term_close();
}

static void begin_edit(AppEditKind kind, const char[..] prompt, const char[..] initial) {
	g_app.edit_kind = kind;
	ui_begin_edit(&g_app.ui, prompt, initial);
}

static void cancel_edit() {
	g_app.edit_kind = EditNone;
	g_app.kill_idx = -1;
	g_app.new_attn[0] = 0;
	ui_end_edit(&g_app.ui);
}

static void do_kill(int idx) {
	if (!g_app.store.remove(idx)) {
		ui_set_status(&g_app.ui, "kill failed");
		return;
	}
	refresh_visible();
	ui_clamp(&g_app.ui);
	ui_set_status(&g_app.ui, "killed");
	save_db_quiet();
}

static bool val_is_all(const char[..] val) {
	return len(val) == 0 || str_eq(val, "*") || str_eq(val, "all");
}

static void apply_edit() {
	int idx = ui_selected_store_index(&g_app.ui);
	char valbuf[TaskTitleCap] = {0};
	AppEditKind kind = g_app.edit_kind;
	snprintf(valbuf, sizeof(valbuf), "%s", g_app.ui.input);
	const char[..] val = ranged(valbuf, strlen(valbuf));
	g_app.edit_kind = EditNone;
	ui_end_edit(&g_app.ui);
	if (kind == EditFilterText) {
		(void)str_set(&g_app.filter.text, val);
		refresh_visible();
		ui_set_status(&g_app.ui, "filter set");
		return;
	}
	if (kind == EditFilterCc) {
		if (val_is_all(val)) {
			(void)str_set(&g_app.filter.cc, "");
			ui_set_status(&g_app.ui, "focus cleared");
		} else {
			(void)str_set(&g_app.filter.cc, val);
			ui_set_status(&g_app.ui, "focus set");
		}
		refresh_visible();
		return;
	}
	if (kind == EditNewAttn) {
		snprintf(g_app.new_attn, sizeof(g_app.new_attn), "%s", valbuf);
		begin_edit(EditNewTitle, "new task: ", "");
		return;
	}
	if (kind == EditNewTitle) {
		Task t = {0};
		char id[TaskIdCap] = {0};
		if (len(val) == 0) {
			g_app.new_attn[0] = 0;
			ui_set_status(&g_app.ui, "cancelled");
			return;
		}
		(void)str_set(&t.title, val);
		(void)str_set(&t.status, "A:Inbox");
		if (!g_app.store.add(&t)) {
			t.clear();
			g_app.new_attn[0] = 0;
			ui_set_status(&g_app.ui, "add failed");
			return;
		}
		t.clear();
		int at = g_app.store.count - 1;
		if (at >= 0 && strlen(g_app.new_attn) != 0) {
			g_app.store.set_cc(at, ranged(g_app.new_attn, strlen(g_app.new_attn)));
		}
		g_app.new_attn[0] = 0;
		if (at >= 0) {
			capture_id(ranged(id, sizeof(id)), &g_app.store.tasks[at]);
		}
		refresh_visible();
		select_task_id(ranged(id, cstr_zlen(ranged(id, sizeof(id)))));
		ui_set_status(&g_app.ui, "added");
		save_db();
		return;
	}
	if (idx < 0) {
		ui_set_status(&g_app.ui, "no selection");
		return;
	}
	if (kind == EditTitle) {
		if (len(val) == 0) {
			ui_set_status(&g_app.ui, "cancelled");
			return;
		}
		g_app.store.set_title(idx, val);
	} else if (kind == EditCc) {
		g_app.store.set_cc(idx, val);
	}
	save_db();
}

static void handle_normal_key(uint32_t key) {
	if (key == 'q' || key == 'Q') {
		if (g_app.store.dirty) {
			save_db();
		}
		g_app.running = false;
		return;
	}
	if (key == (uint32_t)TermKeyUp ||
		key == ((uint32_t)TermCTL | (uint32_t)'P')) {
		if (g_app.ui.selected > 0) {
			g_app.ui.selected--;
		}
		return;
	}
	if (key == (uint32_t)TermKeyDown ||
		key == ((uint32_t)TermCTL | (uint32_t)'N')) {
		if (g_app.ui.selected + 1 < g_app.visible_count) {
			g_app.ui.selected++;
		}
		return;
	}
	/* jem: S-Up / S-Down page; also PageUp/Down and C-v */
	if (key == ((uint32_t)TermSHIFT | (uint32_t)TermKeyUp) ||
		key == (uint32_t)TermKeyPageUp) {
		g_app.ui.selected -= ui_page_rows();
		ui_clamp(&g_app.ui);
		return;
	}
	if (key == ((uint32_t)TermSHIFT | (uint32_t)TermKeyDown) ||
		key == (uint32_t)TermKeyPageDown ||
		key == ((uint32_t)TermCTL | (uint32_t)'V')) {
		g_app.ui.selected += ui_page_rows();
		ui_clamp(&g_app.ui);
		return;
	}
	if (key == 'g') {
		g_app.ui.selected = 0;
		return;
	}
	if (key == 'G') {
		if (g_app.visible_count > 0) {
			g_app.ui.selected = g_app.visible_count - 1;
		}
		return;
	}
	if (key == 'X') {
		g_app.filter.show_complete = !g_app.filter.show_complete;
		refresh_visible();
		ui_set_status(&g_app.ui, g_app.filter.show_complete ? "showing complete" : "hiding complete");
		return;
	}
	if (key == 'o') {
		/* Explicit reorder — edits leave list order alone so rows don't jump. */
		char id[TaskIdCap] = {0};
		capture_id(ranged(id, sizeof(id)), ui_selected_task(&g_app.ui));
		g_app.store.sort();
		refresh_visible();
		select_task_id(ranged(id, cstr_zlen(ranged(id, sizeof(id)))));
		ui_set_status(&g_app.ui, "sorted");
		return;
	}
	if (key == '/') {
		/* Toggle: clear find if set; otherwise prompt (same idea as f). */
		if (len(g_app.filter.text) != 0) {
			(void)str_set(&g_app.filter.text, "");
			refresh_visible();
			ui_set_status(&g_app.ui, "find cleared");
			return;
		}
		begin_edit(EditFilterText, "find: ", "");
		return;
	}
	if (key == 'n') {
		/* Prefill Attn from the selected row (meeting burst / same-person add). */
		Task *cur = ui_selected_task(&g_app.ui);
		const char[..] pre = (cur != NULL && len(cur.cc) != 0) ? cur.cc : str_from_cstr("");
		g_app.new_attn[0] = 0;
		begin_edit(EditNewAttn, "new attn (Tab completes): ", pre);
		return;
	}
	int idx = ui_selected_store_index(&g_app.ui);
	Task *t = ui_selected_task(&g_app.ui);
	if (key == 'f') {
		/* Toggle: clear focus if set; otherwise prompt for CC substring. */
		if (len(g_app.filter.cc) != 0) {
			(void)str_set(&g_app.filter.cc, "");
			refresh_visible();
			ui_set_status(&g_app.ui, "focus cleared");
			return;
		}
		begin_edit(EditFilterCc, "focus (Tab completes): ", "");
		return;
	}
	if (idx < 0 || t == NULL) {
		return;
	}
	if (key == 's') {
		g_app.store.cycle_status(idx);
		refresh_visible();
		ui_set_status(&g_app.ui, t.status);
		save_db_quiet();
		return;
	}
	if (key == 'x') {
		/* Mark complete (hidden from default view unless X). */
		g_app.store.set_status(idx, "F:Complete");
		refresh_visible();
		ui_set_status(&g_app.ui, g_app.filter.show_complete
			? "marked F:Complete"
			: "marked F:Complete (hidden; X to show)");
		save_db_quiet();
		return;
	}
	if (key == 'k') {
		g_app.kill_idx = idx;
		begin_edit(EditKillConfirm, "are you sure? y/n ", "");
		return;
	}
	if (key == 't' || key == (uint32_t)TermKeyEnter) {
		begin_edit(EditTitle, "title: ", t.title);
		return;
	}
	if (key == 'a') {
		begin_edit(EditCc, "attn: ", t.cc);
		return;
	}
}

/* Tab-complete the Attn token at the caret (comma-separated short names). */
static void complete_attn_token() {
	UiState *ui = &g_app.ui;
	int start = ui.input_cursor;
	int end = ui.input_cursor;
	char prefix[64] = {0};
	char done[64] = {0};
	while (start > 0 && ui.input[start - 1] != ',') {
		start--;
	}
	while (start < end && (ui.input[start] == ' ' || ui.input[start] == '\t')) {
		start++;
	}
	while (end < ui.input_len && ui.input[end] != ',') {
		end++;
	}
	int plen = end - start;
	if (plen < 0) {
		plen = 0;
	}
	if (plen >= (int)sizeof(prefix)) {
		plen = (int)sizeof(prefix) - 1;
	}
	if (plen > 0) {
		memcpy(prefix, ui.input + start, plen);
	}
	prefix[plen] = 0;
	if (!g_app.store.attn_complete(ranged(prefix, (size_t)plen), ranged(done, sizeof(done)))) {
		return;
	}
	{
		int dlen = (int)cstr_zlen(ranged(done, sizeof(done)));
		int new_len = ui.input_len - (end - start) + dlen;
		char buf[sizeof(ui.input)] = {0};
		if (new_len < 0 || new_len >= (int)sizeof(ui.input)) {
			return;
		}
		if (start > 0) {
			memcpy(buf, ui.input, start);
		}
		memcpy(buf + start, done, dlen);
		memcpy(buf + start + dlen, ui.input + end, ui.input_len - end);
		buf[new_len] = 0;
		memcpy(ui.input, buf, new_len + 1);
		ui.input_len = new_len;
		ui.input_cursor = start + dlen;
	}
}

static void handle_event(Event *ev) {
	if (ev == NULL) {
		return;
	}
	if (ev.kind == EventQuit) {
		g_app.running = false;
		return;
	}
	if (ev.kind == EventResize) {
		term_refresh_size();
		screen_ensure_size();
		screen_invalidate();
		return;
	}
	if (ev.kind == EventKey) {
		uint32_t key = ev.key_code;
		if (g_app.ui.editing) {
			if (g_app.edit_kind == EditKillConfirm) {
				int idx = g_app.kill_idx;
				if (key == 'y' || key == 'Y') {
					cancel_edit();
					do_kill(idx);
				} else if (key == 'n' || key == 'N' || key == 0x1B ||
					key == ((uint32_t)TermCTL | (uint32_t)'G') ||
					key == (uint32_t)('G' - '@')) {
					cancel_edit();
					ui_set_status(&g_app.ui, "cancelled");
				}
				/* ignore other keys until y/n */
				return;
			}
			if ((g_app.edit_kind == EditFilterCc || g_app.edit_kind == EditCc ||
					g_app.edit_kind == EditNewAttn) &&
				(key == '\t' || key == (uint32_t)TermKeyTab)) {
				complete_attn_token();
				return;
			}
			if (ui_edit_handle_key(&g_app.ui, key)) {
				if (g_app.ui.edit_cancelled) {
					cancel_edit();
					ui_set_status(&g_app.ui, "cancelled");
				} else {
					apply_edit();
				}
			}
			return;
		}
		handle_normal_key(key);
		return;
	}
}

static void usage() {
	fprintf(stderr, "usage: pf [--db path] [--import seed.json]\n");
	fprintf(stderr, "  PFDB env overrides default config path\n");
	fprintf(stderr, "  Requires a Kitty keyboard protocol terminal (Kitty, Ghostty, ...)\n");
}

static bool parse_args(const char[..][..] args, char[..] import_path) {
	size_t i = 1;
	if (ptr(import_path) != NULL && cap(import_path) > 0) {
		(void)snprintf(ptr(import_path), cap(import_path), "%s", "");
	}
	for (; i < len(args); i++) {
		const char[..] a = args[i];
		if (str_eq(a, "--help") || str_eq(a, "-h")) {
			usage();
			return false;
		}
		if (str_eq(a, "--db")) {
			i++;
			if (i >= len(args)) {
				fprintf(stderr, "pf: --db needs a path\n");
				return false;
			}
			(void)cstr_write(ranged(g_app.db_path, sizeof(g_app.db_path)), args[i]);
			continue;
		}
		if (str_eq(a, "--import")) {
			i++;
			if (i >= len(args) || ptr(import_path) == NULL) {
				fprintf(stderr, "pf: --import needs a path\n");
				return false;
			}
			(void)cstr_write(import_path, args[i]);
			g_app.import_only = true;
			continue;
		}
		fprintf(stderr, "pf: unknown arg %.*s\n", (int)len(a), ptr(a));
		usage();
		return false;
	}
	return true;
}

void app_run(const char[..][..] args) {
	char import_path[1024] = {0};
	memset(&g_app, 0, sizeof(g_app));
	g_app.store.init();
	g_app.filter.init();
	ui_init(&g_app.ui, &g_app.store, &g_app.filter, ranged(g_app.visible, VisibleMax));
	g_app.edit_kind = EditNone;
	g_app.kill_idx = -1;
	g_app.running = true;

	if (!store_default_path(ranged(g_app.db_path, sizeof(g_app.db_path)))) {
		snprintf(g_app.db_path, sizeof(g_app.db_path), "tasks.json");
	}
	if (!parse_args(args, ranged(import_path, sizeof(import_path)))) {
		return;
	}

	if (strlen(import_path) != 0) {
		if (!store_import_file(&g_app.store,
			ranged(import_path, strlen(import_path)),
			db_path_view())) {
			fprintf(stderr, "pf: import failed: %s\n", import_path);
			return;
		}
		fprintf(stderr, "pf: imported %d tasks into %s\n", g_app.store.count, g_app.db_path);
		if (g_app.import_only) {
			return;
		}
	} else if (!g_app.store.load(db_path_view())) {
		/* start empty */
		g_app.store.init();
		ui_set_status(&g_app.ui, "new database");
	}
	note_db_mtime();

	refresh_visible();

	crash_init(crash_cleanup);
	if (!term_open()) {
		fprintf(stderr, "pf: term_open failed (need a Kitty-protocol TTY)\n");
		return;
	}
	defer term_close();
	screen_init();
	defer screen_shutdown();

	bool need_paint = true;
	while (g_app.running) {
		Event ev = {EventNone};
		if (need_paint) {
			ui_paint(&g_app.ui);
			need_paint = false;
			/* Drain keys that arrived during paint (jem harvest pattern). */
			for (;;) {
				auto (key, ok) = term_try_read_key(0);
				if (!ok) {
					break;
				}
				event_enqueue(event_key(key));
			}
		}
		while (event_try_dequeue(&ev)) {
			handle_event(&ev);
			event_free(&ev);
			need_paint = true;
			if (!g_app.running) {
				break;
			}
		}
		if (!g_app.running) {
			break;
		}
		if (need_paint) {
			continue;
		}
		if (maybe_reload_db()) {
			need_paint = true;
			continue;
		}
		{
			auto (key, ok) = term_try_read_key(100);
			if (ok) {
				event_enqueue(event_key(key));
				need_paint = true;
			}
		}
	}
	if (g_app.store.dirty) {
		save_db();
	}
}
