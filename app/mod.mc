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
	EditDue = 2,
	EditNotes = 3,
	EditCc = 4,
	EditFilterText = 5,
	EditNewTitle = 6,
	EditFilterCc = 7
};

struct App {
	TaskStore store;
	ViewFilter filter;
	int visible[VisibleMax];
	int visible_count;
	UiState ui;
	char db_path[1024];
	AppEditKind edit_kind;
	bool running;
	bool import_only;
	int64_t db_mtime_ns;
	bool db_mtime_ok;
};

static App g_app;

static void note_db_mtime() {
	auto (info, ok) = fs_stat(ranged(g_app.db_path, strlen(g_app.db_path)));
	g_app.db_mtime_ok = ok;
	g_app.db_mtime_ns = ok ? info.mtime_ns : 0;
}

static void refresh_visible() {
	g_app.visible_count = model_build_visible(&g_app.store, &g_app.filter,
		ranged(g_app.visible, VisibleMax));
	g_app.ui.visible_count = g_app.visible_count;
	ui_clamp(&g_app.ui);
}

static void select_task_id(const char *id) {
	int i = 0;
	if (id == NULL || strlen(id) == 0) {
		return;
	}
	for (; i < g_app.visible_count; i++) {
		Task *t = model_get(&g_app.store, g_app.visible[i]);
		if (t != NULL && strcmp(t.id, id) == 0) {
			g_app.ui.selected = i;
			ui_clamp(&g_app.ui);
			return;
		}
	}
}

static void mark_saved() {
	ui_set_status(&g_app.ui, "saved");
}

/* Persist without clobbering a status/category flash message. */
static bool save_db_quiet() {
	if (!store_save(&g_app.store, ranged(g_app.db_path, strlen(g_app.db_path)))) {
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
	auto (info, ok) = fs_stat(ranged(g_app.db_path, strlen(g_app.db_path)));
	if (!ok) {
		return false;
	}
	if (g_app.db_mtime_ok && info.mtime_ns == g_app.db_mtime_ns) {
		return false;
	}
	Task *cur = ui_selected_task(&g_app.ui);
	if (cur != NULL) {
		snprintf(id, sizeof(id), "%s", cur.id);
	}
	if (!store_load(&g_incoming, ranged(g_app.db_path, strlen(g_app.db_path)))) {
		/* Keep last-good mtime so a partial Syncthing write is retried. */
		ui_set_status(&g_app.ui, "reload failed");
		return true;
	}
	bool changed = store_merge(&g_app.store, &g_incoming);
	note_db_mtime();
	if (changed) {
		(void)save_db_quiet();
		ui_set_status(&g_app.ui, "merged");
	}
	refresh_visible();
	select_task_id(id);
	return true;
}

static void crash_cleanup() {
	term_close();
}

static void begin_edit(AppEditKind kind, const char *prompt, const char *initial) {
	g_app.edit_kind = kind;
	ui_begin_edit(&g_app.ui, prompt, initial);
}

static void cancel_edit() {
	g_app.edit_kind = EditNone;
	ui_end_edit(&g_app.ui);
}

static bool val_is_all(const char[..] val) {
	return len(val) == 0 || str_eq(val, "*") || str_eq(val, "all");
}

static void apply_edit() {
	int idx = ui_selected_store_index(&g_app.ui);
	char valbuf[TaskNotesCap] = {0};
	AppEditKind kind = g_app.edit_kind;
	snprintf(valbuf, sizeof(valbuf), "%s", g_app.ui.input);
	const char[..] val = ranged(valbuf, strlen(valbuf));
	g_app.edit_kind = EditNone;
	ui_end_edit(&g_app.ui);
	if (kind == EditFilterText) {
		snprintf(g_app.filter.text, sizeof(g_app.filter.text), "%s", valbuf);
		refresh_visible();
		ui_set_status(&g_app.ui, "filter set");
		return;
	}
	if (kind == EditFilterCc) {
		if (val_is_all(val)) {
			snprintf(g_app.filter.cc, sizeof(g_app.filter.cc), "%s", "");
			ui_set_status(&g_app.ui, "focus cleared");
		} else {
			snprintf(g_app.filter.cc, sizeof(g_app.filter.cc), "%s", valbuf);
			ui_set_status(&g_app.ui, "focus set");
		}
		refresh_visible();
		return;
	}
	if (kind == EditNewTitle) {
		Task t = {0};
		if (len(val) == 0) {
			ui_set_status(&g_app.ui, "cancelled");
			return;
		}
		snprintf(t.title, sizeof(t.title), "%s", valbuf);
		snprintf(t.status, sizeof(t.status), "A:Next");
		snprintf(t.category, sizeof(t.category), "Other");
		if (!model_add(&g_app.store, &t)) {
			ui_set_status(&g_app.ui, "add failed");
			return;
		}
		refresh_visible();
		{
			int i = 0;
			for (; i < g_app.visible_count; i++) {
				Task *x = model_get(&g_app.store, g_app.visible[i]);
				if (x != NULL && strcmp(x.title, valbuf) == 0) {
					g_app.ui.selected = i;
					break;
				}
			}
		}
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
		model_set_title(&g_app.store, idx, valbuf);
	} else if (kind == EditDue) {
		model_set_due(&g_app.store, idx, valbuf);
	} else if (kind == EditNotes) {
		model_set_notes(&g_app.store, idx, valbuf);
	} else if (kind == EditCc) {
		model_set_cc(&g_app.store, idx, valbuf);
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
		Task *cur = ui_selected_task(&g_app.ui);
		char id[TaskIdCap] = {0};
		if (cur != NULL) {
			snprintf(id, sizeof(id), "%s", cur.id);
		}
		model_sort(&g_app.store);
		refresh_visible();
		select_task_id(id);
		ui_set_status(&g_app.ui, "sorted");
		return;
	}
	if (key == '/') {
		begin_edit(EditFilterText, "find: ", g_app.filter.text);
		return;
	}
	if (key == 'n') {
		begin_edit(EditNewTitle, "new task: ", "");
		return;
	}
	int idx = ui_selected_store_index(&g_app.ui);
	Task *t = ui_selected_task(&g_app.ui);
	if (key == 'f') {
		/* Toggle: clear focus if set; otherwise prompt for CC substring. */
		if (strlen(g_app.filter.cc) != 0) {
			snprintf(g_app.filter.cc, sizeof(g_app.filter.cc), "%s", "");
			refresh_visible();
			ui_set_status(&g_app.ui, "focus cleared");
			return;
		}
		begin_edit(EditFilterCc, "focus attn (* for all): ", "");
		return;
	}
	if (idx < 0 || t == NULL) {
		return;
	}
	if (key == 's') {
		model_cycle_status(&g_app.store, idx);
		refresh_visible();
		ui_set_status(&g_app.ui, t.status);
		save_db_quiet();
		return;
	}
	if (key == 'x') {
		/* Mark complete (hidden from default view unless X). */
		model_set_status(&g_app.store, idx, "E:Complete");
		refresh_visible();
		ui_set_status(&g_app.ui, g_app.filter.show_complete
			? "marked E:Complete"
			: "marked E:Complete (hidden; X to show)");
		save_db_quiet();
		return;
	}
	if (key == 'c') {
		model_cycle_category(&g_app.store, idx);
		refresh_visible();
		ui_set_status(&g_app.ui, t.category);
		save_db_quiet();
		return;
	}
	if (key == 't' || key == (uint32_t)TermKeyEnter) {
		begin_edit(EditTitle, "title: ", t.title);
		return;
	}
	if (key == 'd') {
		begin_edit(EditDue, "due: ", t.due);
		return;
	}
	if (key == 'w') {
		begin_edit(EditNotes, "writeup: ", t.notes);
		return;
	}
	if (key == 'a') {
		begin_edit(EditCc, "attn: ", t.cc);
		return;
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
			if (ui_edit_handle_key(&g_app.ui, key)) {
				if (g_app.ui.input_len == 0 && key == 0x1B) {
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
	fprintf(stderr, "usage: q2 [--db path] [--import seed.json]\n");
	fprintf(stderr, "  Q2DB env overrides default config path\n");
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
				fprintf(stderr, "q2: --db needs a path\n");
				return false;
			}
			snprintf(g_app.db_path, sizeof(g_app.db_path), "%s", args[i]);
			continue;
		}
		if (str_eq(a, "--import")) {
			i++;
			if (i >= len(args) || ptr(import_path) == NULL) {
				fprintf(stderr, "q2: --import needs a path\n");
				return false;
			}
			(void)snprintf(ptr(import_path), cap(import_path), "%s", args[i]);
			g_app.import_only = true;
			continue;
		}
		fprintf(stderr, "q2: unknown arg %s\n", a);
		usage();
		return false;
	}
	return true;
}

void app_run(const char[..][..] args) {
	char import_path[1024] = {0};
	memset(&g_app, 0, sizeof(g_app));
	model_init(&g_app.store);
	model_filter_init(&g_app.filter);
	ui_init(&g_app.ui, &g_app.store, &g_app.filter, ranged(g_app.visible, VisibleMax));
	g_app.edit_kind = EditNone;
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
			ranged(g_app.db_path, strlen(g_app.db_path)))) {
			fprintf(stderr, "q2: import failed: %s\n", import_path);
			return;
		}
		fprintf(stderr, "q2: imported %d tasks into %s\n", g_app.store.count, g_app.db_path);
		if (g_app.import_only) {
			return;
		}
	} else if (!store_load(&g_app.store, ranged(g_app.db_path, strlen(g_app.db_path)))) {
		/* start empty */
		model_init(&g_app.store);
		ui_set_status(&g_app.ui, "new database");
	}
	note_db_mtime();

	refresh_visible();

	crash_init(crash_cleanup);
	if (!term_open()) {
		fprintf(stderr, "q2: term_open failed (need a Kitty-protocol TTY)\n");
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
